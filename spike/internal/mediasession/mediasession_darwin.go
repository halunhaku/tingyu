//go:build darwin

// Package mediasession publishes the playing track to macOS Now Playing and
// receives the media keys through MPRemoteCommandCenter, without cgo: the
// MediaPlayer framework is driven through the Objective-C runtime with purego.
//
// Every Objective-C object is created and messaged on the main thread through
// mainq.Post, so the package is safe to call from the player's goroutines. The
// command blocks only enqueue into a channel; SetHandler's callback runs on a
// goroutine of this package, never on macOS's.
package mediasession

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/ebitengine/purego/objc"
	"github.com/halunhaku/tingyu/spike/internal/mainq"
)

// Command is one transport command the system asks for.
type Command int

const (
	CmdPlay Command = iota
	CmdPause
	CmdToggle
	CmdNext
	CmdPrev
	CmdSeek // arg is the requested position, in seconds
)

// Metadata is the track description Now Playing shows.
type Metadata struct {
	Title       string
	Artist      string
	Album       string
	DurationSec float64
	ArtPath     string // local PNG/JPEG cover; may be empty
}

// State is the playback state Now Playing shows.
type State struct {
	Playing  bool
	Rate     float64
	Position float64
	Duration float64
}

// commandSpec is one MPRemoteCommand we register; index == int(Command).
type commandSpec struct {
	cmd      Command
	selector string
	name     string
	seek     bool
	enabled  bool // the state Init leaves the command in
}

var commandSpecs = [...]commandSpec{
	CmdPlay:   {cmd: CmdPlay, selector: "playCommand", name: "play", enabled: true},
	CmdPause:  {cmd: CmdPause, selector: "pauseCommand", name: "pause", enabled: true},
	CmdToggle: {cmd: CmdToggle, selector: "togglePlayPauseCommand", name: "togglePlayPause", enabled: true},
	CmdNext:   {cmd: CmdNext, selector: "nextTrackCommand", name: "nextTrack"},
	CmdPrev:   {cmd: CmdPrev, selector: "previousTrackCommand", name: "previousTrack"},
	CmdSeek:   {cmd: CmdSeek, selector: "changePlaybackPositionCommand", name: "changePlaybackPosition", seek: true, enabled: true},
}

// String returns the command's Now Playing name, e.g. "togglePlayPause".
func (c Command) String() string {
	if int(c) < 0 || int(c) >= len(commandSpecs) {
		return fmt.Sprintf("Command(%d)", int(c))
	}
	return commandSpecs[c].name
}

// maxArtSide is the artwork size cap; MediaPlayer asks for its own sizes and
// scales, so a large cover only wastes memory.
const maxArtSide = 512

// maxRetiredArtwork bounds the covers kept after a change, so that a late
// requestHandler call cannot observe a released image.
const maxRetiredArtwork = 2

// The command callbacks may run on any thread; they only enqueue here and the
// single pump goroutine calls the user's handler.
type event struct {
	cmd Command
	arg float64
}

var (
	events = make(chan event, 64)

	pumpOnce  sync.Once
	handlerMu sync.RWMutex
	handler   func(cmd Command, arg float64)

	initOnce sync.Once
	initErr  error

	center objc.ID // MPNowPlayingInfoCenter.defaultCenter
	remote objc.ID // MPRemoteCommandCenter.sharedCommandCenter

	// Main-thread only, like everything else that touches Objective-C.
	// commandBlocks keeps each registered handler block alive for the life of
	// the process; the command objects retain their targets too, but holding
	// the Block values makes that explicit.
	commandObjects [len(commandSpecs)]objc.ID
	commandBlocks  [len(commandSpecs)]objc.Block

	// Main-thread only artwork cache. key identifies the file, so an unchanged
	// cover is never rebuilt.
	artwork    objc.ID
	artBlock   objc.Block
	artImage   objc.ID
	artKey     string
	artRetired []retiredArt

	// mu guards the Go-side snapshot that apply() turns into the info
	// dictionary.
	mu    sync.Mutex
	meta  Metadata
	state State
)

type retiredArt struct {
	block objc.Block
	image objc.ID
}

// Init loads the frameworks, creates the command handlers and is safe to call
// repeatedly.
func Init() error {
	initOnce.Do(func() { initErr = initSession() })
	return initErr
}

func initSession() error {
	if err := loadFrameworks(); err != nil {
		return err
	}
	pumpOnce.Do(startEventPump)
	var err error
	if waitErr := applyOnMain(func() {
		center = msgID(class("MPNowPlayingInfoCenter"), sel("defaultCenter"))
		remote = msgID(class("MPRemoteCommandCenter"), sel("sharedCommandCenter"))
		if center == 0 || remote == 0 {
			err = errors.New("mediasession: MediaPlayer has no Now Playing or remote command center")
			return
		}
		for i := range commandSpecs {
			spec := commandSpecs[i]
			cmd := msgID(remote, sel(spec.selector))
			if cmd == 0 {
				err = fmt.Errorf("mediasession: remote command center has no %s", spec.selector)
				return
			}
			commandObjects[i] = cmd
			commandBlocks[i] = attachHandler(cmd, spec)
			msgVoidBool(cmd, sel("setEnabled:"), spec.enabled)
		}
	}); waitErr != nil {
		return waitErr
	}
	return err
}

// attachHandler registers the block for cmd and returns it so the registration
// keeps its handler alive.
func attachHandler(cmd objc.ID, spec commandSpec) objc.Block {
	var block objc.Block
	if spec.seek {
		block = objc.NewBlock(func(_ objc.Block, ev objc.ID) int64 {
			pushEvent(spec.cmd, msgDouble(ev, sel("positionTime")))
			return commandStatusSuccess
		})
	} else {
		block = objc.NewBlock(func(objc.Block, objc.ID) int64 {
			pushEvent(spec.cmd, 0)
			return commandStatusSuccess
		})
	}
	msgIDBlock(cmd, sel("addTargetWithHandler:"), block)
	return block
}

// pushEvent hands a command over to the pump without ever blocking macOS.
func pushEvent(cmd Command, arg float64) {
	select {
	case events <- event{cmd: cmd, arg: arg}:
	default:
		// The consumer is behind; dropping the press beats stalling the system.
	}
}

func startEventPump() {
	go func() {
		for ev := range events {
			handlerMu.RLock()
			fn := handler
			handlerMu.RUnlock()
			if fn != nil {
				fn(ev.cmd, ev.arg)
			}
		}
	}()
}

// SetHandler installs the callback for media keys. arg is only meaningful for
// CmdSeek. Pass nil to stop receiving commands.
func SetHandler(fn func(cmd Command, arg float64)) {
	pumpOnce.Do(startEventPump)
	handlerMu.Lock()
	handler = fn
	handlerMu.Unlock()
}

// SetMetadata publishes title/artist/album/duration/artwork and the external
// content identifier.
func SetMetadata(m Metadata) error {
	if err := Init(); err != nil {
		return err
	}
	mu.Lock()
	meta = m
	mu.Unlock()
	var artErr error
	if err := applyOnMain(func() { artErr = apply() }); err != nil {
		return err
	}
	return artErr
}

// SetState publishes the playback state, rate and position (and the
// MPNowPlayingPlaybackState the system uses to pick the transport buttons).
//
// It does not report artwork problems: SetMetadata owns the cover, and a player
// calls SetState on every tick.
func SetState(s State) error {
	if err := Init(); err != nil {
		return err
	}
	mu.Lock()
	state = s
	mu.Unlock()
	return applyOnMain(func() { _ = apply() })
}

// SetEnabledCommands turns the next/previous buttons on or off.
func SetEnabledCommands(hasNext, hasPrev bool) error {
	if err := Init(); err != nil {
		return err
	}
	return applyOnMain(func() {
		setEnabled(CmdNext, hasNext)
		setEnabled(CmdPrev, hasPrev)
	})
}

// Clear empties nowPlayingInfo, parks the playback state at stopped, drops the
// artwork and releases the App Nap / idle sleep assertions.
func Clear() error {
	if err := Init(); err != nil {
		return err
	}
	if err := applyOnMain(func() {
		msgVoidID(center, sel("setNowPlayingInfo:"), 0)
		msgVoidInt64(center, sel("setPlaybackState:"), playbackStateStopped)
		if artwork != 0 {
			retireArtwork()
		}
		// nowPlayingInfo is empty, so MediaPlayer has let go of the artwork
		// objects; their blocks and images can go too.
		for _, old := range artRetired {
			old.block.Release()
			msgVoid(old.image, sel("release"))
		}
		artRetired = nil
	}); err != nil {
		return err
	}
	mu.Lock()
	meta, state = Metadata{}, State{}
	mu.Unlock()
	return SetKeepsAwake(false)
}

// NowPlayingInfo reads MPNowPlayingInfoCenter.nowPlayingInfo back with readable
// keys: title, artist, album, duration, elapsed, rate,
// externalContentIdentifier, artworkPresent and playbackState.
func NowPlayingInfo() (map[string]any, error) {
	if err := Init(); err != nil {
		return nil, err
	}
	out := make(map[string]any, 9)
	if err := applyOnMain(func() {
		info := msgID(center, sel("nowPlayingInfo"))
		if info == 0 {
			return
		}
		object := func(key objc.ID) objc.ID {
			if key == 0 {
				return 0
			}
			return msgIDID(info, sel("objectForKey:"), key)
		}
		if s, ok := nsStringOf(object(keys.title)); ok {
			out["title"] = s
		}
		if s, ok := nsStringOf(object(keys.artist)); ok {
			out["artist"] = s
		}
		if s, ok := nsStringOf(object(keys.album)); ok {
			out["album"] = s
		}
		if f, ok := nsFloatOf(object(keys.duration)); ok {
			out["duration"] = f
		}
		if f, ok := nsFloatOf(object(keys.elapsed)); ok {
			out["elapsed"] = f
		}
		if f, ok := nsFloatOf(object(keys.rate)); ok {
			out["rate"] = f
		}
		if s, ok := nsStringOf(object(keys.externalID)); ok {
			out["externalContentIdentifier"] = s
		}
		out["artworkPresent"] = object(keys.artwork) != 0
		out["playbackState"] = msgInt64(center, sel("playbackState"))
	}); err != nil {
		return nil, err
	}
	return out, nil
}

// CommandStatus lists the registered commands the system currently offers.
func CommandStatus() ([]string, error) {
	if err := Init(); err != nil {
		return nil, err
	}
	var out []string
	if err := applyOnMain(func() {
		out = make([]string, 0, len(commandSpecs))
		for i := range commandSpecs {
			cmd := commandObjects[i]
			if cmd != 0 && msgBool(cmd, sel("isEnabled")) {
				out = append(out, commandSpecs[i].name)
			}
		}
	}); err != nil {
		return nil, err
	}
	return out, nil
}

// apply pushes the current metadata and state to MPNowPlayingInfoCenter. It
// must run on the main thread.
func apply() error {
	mu.Lock()
	m, s := meta, state
	mu.Unlock()

	art, artErr := ensureArtwork(m.ArtPath)

	info := msgID(class("NSMutableDictionary"), sel("dictionary"))
	setObject := func(key, value objc.ID) {
		// setObject:forKey: throws on nil, and a missing key symbol must not
		// take the process down.
		if key != 0 && value != 0 {
			msgVoidIDID(info, sel("setObject:forKey:"), value, key)
		}
	}
	setObject(keys.title, nsString(m.Title))
	setObject(keys.artist, nsString(m.Artist))
	setObject(keys.album, nsString(m.Album))
	duration := s.Duration
	if duration <= 0 {
		duration = m.DurationSec
	}
	if duration > 0 {
		setObject(keys.duration, nsNumber(duration))
	}
	setObject(keys.elapsed, nsNumber(s.Position))
	rate := 0.0
	if s.Playing {
		rate = s.Rate
		if rate <= 0 {
			rate = 1
		}
	}
	setObject(keys.rate, nsNumber(rate))
	setObject(keys.defaultRate, nsNumber(1))
	setObject(keys.mediaType, nsNumberUint(mediaTypeAudio))
	if id := externalContentID(m); id != "" {
		setObject(keys.externalID, nsString(id))
	}
	if art != 0 {
		setObject(keys.artwork, art)
	}

	msgVoidID(center, sel("setNowPlayingInfo:"), info)
	msgVoidInt64(center, sel("setPlaybackState:"), playbackState(s))
	return artErr
}

// playbackState maps State to MPNowPlayingPlaybackState.
func playbackState(s State) int64 {
	if s.Playing {
		return playbackStatePlaying
	}
	return playbackStatePaused
}

// externalContentID derives MPNowPlayingInfoPropertyExternalContentIdentifier
// from the metadata, since the shim carries no track identity of its own.
func externalContentID(m Metadata) string {
	parts := make([]string, 0, 3)
	for _, p := range []string{m.Title, m.Artist, m.Album} {
		if p != "" {
			parts = append(parts, p)
		}
	}
	if len(parts) == 0 {
		return ""
	}
	return "tingyu:" + strings.Join(parts, "|")
}

// ensureArtwork returns the MPMediaItemArtwork of path, reusing the previous
// one while the file is unchanged. Main thread only.
//
// The request handler block captures its NSImage by value, so MediaPlayer may
// call it from any thread without reading shared state.
func ensureArtwork(path string) (objc.ID, error) {
	if path == "" {
		if artwork != 0 {
			retireArtwork()
		}
		return 0, nil
	}
	st, err := os.Stat(path)
	if err != nil {
		if artwork != 0 {
			retireArtwork()
		}
		return 0, fmt.Errorf("mediasession: artwork: %w", err)
	}
	key := fmt.Sprintf("%s\x00%d\x00%d", path, st.Size(), st.ModTime().UnixNano())
	if artwork != 0 && key == artKey {
		return artwork, nil
	}
	if artwork != 0 {
		retireArtwork()
	}

	image := msgIDID(msgID(class("NSImage"), sel("alloc")), sel("initWithContentsOfFile:"), nsString(path))
	if image == 0 {
		return 0, fmt.Errorf("mediasession: artwork: cannot load image %s", path)
	}
	block := objc.NewBlock(func(objc.Block, cgSize) objc.ID { return image })
	art := msgIDSizeBlock(msgID(class("MPMediaItemArtwork"), sel("alloc")),
		sel("initWithBoundsSize:requestHandler:"), artBounds(msgSize(image, sel("size"))), block)
	if art == 0 {
		block.Release()
		msgVoid(image, sel("release"))
		return 0, errors.New("mediasession: artwork: MPMediaItemArtwork rejected the handler")
	}
	artwork, artBlock, artImage, artKey = art, block, image, key
	return art, nil
}

// artBounds caps the artwork at maxArtSide, keeping the aspect ratio.
func artBounds(size cgSize) cgSize {
	if size.Width <= 0 || size.Height <= 0 {
		return cgSize{Width: maxArtSide, Height: maxArtSide}
	}
	side := max(size.Width, size.Height)
	if side <= maxArtSide {
		return size
	}
	scale := maxArtSide / side
	return cgSize{Width: size.Width * scale, Height: size.Height * scale}
}

// retireArtwork drops the current artwork, keeping the last few blocks and
// images alive so a late requestHandler call cannot see a released image.
// Main thread only.
func retireArtwork() {
	artRetired = append(artRetired, retiredArt{block: artBlock, image: artImage})
	artwork, artBlock, artImage, artKey = 0, 0, 0, ""
	for len(artRetired) > maxRetiredArtwork {
		old := artRetired[0]
		artRetired = artRetired[1:]
		old.block.Release()
		msgVoid(old.image, sel("release"))
	}
}

// setEnabled toggles a registered command. Main thread only.
func setEnabled(cmd Command, on bool) {
	if obj := commandObject(cmd); obj != 0 {
		msgVoidBool(obj, sel("setEnabled:"), on)
	}
}

// commandObject returns the registered MPRemoteCommand for cmd, or 0.
func commandObject(cmd Command) objc.ID {
	if int(cmd) < 0 || int(cmd) >= len(commandObjects) {
		return 0
	}
	return commandObjects[cmd]
}

// mainThreadWait bounds how long a caller waits for the main thread to run an
// operation. Without a run loop and off the main thread nothing ever will, and
// reporting that beats hanging inside a media key handler.
const mainThreadWait = 5 * time.Second

// applyOnMain runs f on the main thread and waits for it, so that a sequence of
// setters is applied in order and reads see their own writes.
func applyOnMain(f func()) error {
	if mainq.OnMainThread() {
		// Post runs inline here, so the operation is already applied.
		mainq.Post(f)
		return nil
	}
	done := make(chan struct{})
	mainq.Post(func() {
		defer close(done)
		f()
	})
	select {
	case <-done:
		return nil
	case <-time.After(mainThreadWait):
		return errors.New("mediasession: the main thread did not run the operation (no run loop, or not called from the main thread)")
	}
}
