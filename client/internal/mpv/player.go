package mpv

import (
	"errors"
	"fmt"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"
)

// Item is one entry of the player's playlist. Headers are per-URI HTTP
// headers (WebDAV Basic, Quark playback headers); mpv 0.36 does not accept
// them as loadfile arguments, so they are applied in the on_load hook.
type Item struct {
	URI     string
	Headers map[string]string
}

// FailureKind classifies a failure so the UI can say something a person can
// act on. mpv's own error is a generic "Failed to open" for every cause; the
// HTTP status and transport failures are only visible in the lines FFmpeg logs
// (see loadFailure), which is what turns a 401 into "the link expired or you
// have no permission" instead of a dead end.
type FailureKind int

const (
	// FailureUnknown is a load failure nothing in the log explained.
	FailureUnknown FailureKind = iota
	// FailureNetwork means the server could not be reached at all.
	FailureNetwork
	// FailureUnauthorized covers 401/403 and expired direct links.
	FailureUnauthorized
	// FailureNotFound covers 404 and local files that no longer exist.
	FailureNotFound
	// FailureDecode means the bytes arrived but could not be decoded.
	FailureDecode
)

func (k FailureKind) String() string {
	switch k {
	case FailureNetwork:
		return "network"
	case FailureUnauthorized:
		return "unauthorized"
	case FailureNotFound:
		return "not-found"
	case FailureDecode:
		return "decode"
	}
	return "unknown"
}

// Failure is a load/decode failure. It travels in Snapshot, never as an error
// to the caller: the UI listens to snapshots (plan §4.4).
type Failure struct {
	Kind FailureKind
	// Message is the user-facing sentence (Chinese, actionable).
	Message string
	// Detail is the engine's own text, for logs and bug reports. It never
	// replaces Message in the UI.
	Detail string
	// Status is the HTTP status when the log carried one, else 0.
	Status int
	Title  string // filled by the controller, which knows the track
}

// Processing is the playback phase a UI shows.
type Processing int

const (
	Idle Processing = iota
	Loading
	Buffering
	Ready
	Completed
)

func (p Processing) String() string {
	switch p {
	case Loading:
		return "loading"
	case Buffering:
		return "buffering"
	case Ready:
		return "ready"
	case Completed:
		return "completed"
	}
	return "idle"
}

// Snapshot is the player state at one instant.
type Snapshot struct {
	At         time.Time
	Processing Processing
	Playing    bool
	Paused     bool
	Position   time.Duration
	Duration   time.Duration
	Buffered   time.Duration
	Index      int
	Rate       float64
	Volume     float64
	Path       string
	Failure    *Failure
	Underruns  int
}

// Config configures a Player.
type Config struct {
	// Options are extra mpv options applied before initialize.
	Options map[string]string
	// AudioClientName is what the audio device calls this app.
	AudioClientName string
	// LogLevel raises mpv's log level above the default "warn" (info, debug,
	// trace). At any level above warn every message also goes to Debug, which
	// is how the acceptance harness counts audio-device rebuilds.
	LogLevel string
	// Debug logs notable events when non-nil.
	Debug func(format string, args ...any)
}

// Player owns one mpv core. All methods are safe from any goroutine;
// mpv_wait_event runs on exactly one goroutine (mpv's requirement).
type Player struct {
	lib *Lib
	ctx unsafe.Pointer
	cfg Config

	mu       sync.Mutex
	closed   bool
	closeErr error

	items  []Item
	header map[string]string // uri → http-header-fields

	paused         bool
	idle           bool
	completed      bool
	pausedForCache bool
	position       float64
	duration       float64
	volume         float64
	speed          float64
	cacheBuffering int64
	cacheTime      float64
	path           string
	index          int

	// needsReload marks a playlist entry whose last load failed. Play then has
	// to re-issue playlist-play-index: mpv keeps the entry but sets pause=no on
	// an idle core does nothing, which is exactly the dead play button users
	// hit after a dropped network.
	needsReload bool
	// headerApplied is the http-header-fields value currently set on the core,
	// so switching to a file without headers clears the previous ones instead
	// of leaking the last track's Authorization to the next URL.
	headerApplied string
	// loadStatus and loadLog belong to the current load attempt (reset on
	// start-file). FFmpeg reports the HTTP status and transport errors only in
	// its log lines, and those lines are the difference between a readable
	// "link expired" and a useless "loading failed".
	loadStatus int
	loadLog    []string

	filesLoaded int
	underruns   int
	aoInits     int
	lastError   string
	failure     *Failure
	lastPos     float64
	lastPublish time.Time
	dirty       bool

	subs   map[int]chan Snapshot
	nextID int

	done chan struct{}
	wg   sync.WaitGroup
}

// NewPlayer creates an idle core, applies the options, observes the
// properties the UI needs, and starts the event loop.
func NewPlayer(lib *Lib, cfg Config) (*Player, error) {
	ctx := lib.create()
	if ctx == nil {
		return nil, errors.New("mpv: mpv_create returned NULL")
	}
	p := &Player{lib: lib, ctx: ctx, cfg: cfg, subs: map[int]chan Snapshot{}, done: make(chan struct{}), index: -1}
	options := map[string]string{
		"idle":          "yes",
		"vo":            "null",
		"audio-display": "no",
		"gapless-audio": "yes",
		"ao":            "coreaudio",
		"volume-max":    "100",
		"keep-open":     "no",
		"terminal":      "no",
		// Never load the user's mpv.conf: this process embeds mpv, and a
		// stray option would silently change playback. Scripts, OSD and input
		// bindings are not compiled into media_kit's audio-only build, so
		// options naming them are rejected by mpv (spike §6.3).
		"config":            "no",
		"audio-client-name": "听屿",
	}
	if cfg.AudioClientName != "" {
		options["audio-client-name"] = cfg.AudioClientName
	}
	for key, value := range cfg.Options {
		options[key] = value
	}
	for _, key := range sortedKeys(options) {
		value := options[key]
		rc := lib.setOptionString(ctx, bp(key), bp(value))
		runtime.KeepAlive(key)
		runtime.KeepAlive(value)
		if rc < 0 {
			lib.terminateDestroy(ctx)
			return nil, fmt.Errorf("mpv: set %s=%s: %s", key, value, lib.ErrorString(rc))
		}
	}
	if rc := lib.initialize(ctx); rc < 0 {
		lib.terminateDestroy(ctx)
		return nil, fmt.Errorf("mpv: initialize: %s", lib.ErrorString(rc))
	}
	if rc := lib.requestLog(ctx, bp(p.logLevel())); rc < 0 {
		p.Close()
		return nil, fmt.Errorf("mpv: request_log_messages: %s", lib.ErrorString(rc))
	}
	// on_load: set http-header-fields for the file about to open.
	if rc := lib.hookAdd(ctx, 0, bp("on_load"), 0); rc < 0 {
		p.Close()
		return nil, fmt.Errorf("mpv: hook_add(on_load): %s", lib.ErrorString(rc))
	}
	observed := []struct {
		name   string
		format int32
		id     uint64
	}{
		{"pause", FormatFlag, 1},
		{"playback-time", FormatDouble, 3},
		{"duration", FormatDouble, 4},
		{"idle-active", FormatFlag, 5},
		{"volume", FormatDouble, 6},
		{"speed", FormatDouble, 7},
		{"cache-buffering-state", FormatInt64, 8},
		{"path", FormatString, 9},
		{"playlist-pos", FormatInt64, 10},
		{"paused-for-cache", FormatFlag, 11},
		{"demuxer-cache-time", FormatDouble, 12},
	}
	for _, o := range observed {
		if rc := lib.observeProperty(ctx, o.id, bp(o.name), o.format); rc < 0 {
			p.Close()
			return nil, fmt.Errorf("mpv: observe %s: %s", o.name, lib.ErrorString(rc))
		}
	}
	p.mu.Lock()
	p.volume = 100
	p.speed = 1
	p.mu.Unlock()

	p.wg.Add(1)
	go p.loop()
	return p, nil
}

// logLevel is mpv's requested log level; warn unless the caller asked for
// more detail.
func (p *Player) logLevel() string {
	switch strings.ToLower(strings.TrimSpace(p.cfg.LogLevel)) {
	case "info":
		return "info"
	case "debug":
		return "debug"
	case "trace":
		return "trace"
	}
	return "warn"
}

var propNames = map[uint64]string{
	1: "pause", 3: "playback-time", 4: "duration",
	5: "idle-active", 6: "volume", 7: "speed", 8: "cache-buffering-state",
	9: "path", 10: "playlist-pos", 11: "paused-for-cache", 12: "demuxer-cache-time",
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// loop is the only goroutine that calls mpv_wait_event.
func (p *Player) loop() {
	defer p.wg.Done()
	for {
		select {
		case <-p.done:
			return
		default:
		}
		eventPtr := p.lib.waitEvent(p.ctx, 0.1)
		if eventPtr == nil {
			continue
		}
		event := (*cEvent)(eventPtr)
		if event.EventID == 0 {
			// Timeout: flush a pending property update.
			p.publish(false)
			continue
		}
		name := p.lib.EventName(event.EventID)
		switch name {
		case "log-message":
			p.onLogMessage(event)
		case "hook":
			p.onHook(event)
		case "property-change":
			p.onProperty(event)
		case "end-file":
			p.onEndFile(event)
		case "start-file":
			p.onStartFile()
		case "file-loaded":
			p.onFileLoaded()
		case "playlist-pos":
			p.forcePublish()
		case "shutdown":
			p.publish(true)
			return
		}
	}
}

func (p *Player) onLogMessage(event *cEvent) {
	if event.Data == nil {
		return
	}
	message := (*cEventLogMessage)(event.Data)
	level := goString(unsafe.Pointer(message.Level))
	prefix := goString(unsafe.Pointer(message.Prefix))
	text := goString(unsafe.Pointer(message.Text))
	severity := strings.ToLower(level)
	p.mu.Lock()
	if severity == "error" || severity == "fatal" {
		p.lastError = strings.TrimSpace(text)
	}
	if strings.Contains(strings.ToLower(text), "underrun") {
		p.underruns++
	}
	// "AO: [coreaudio] 48000Hz …" is printed once per audio device
	// (re)initialization. One line across an album is the structural half of
	// the gapless evidence: the device stream was never torn down.
	if strings.Contains(text, "AO: [") {
		p.aoInits++
	}
	if severity == "error" || severity == "warn" || severity == "fatal" {
		p.recordLoadSignal(text)
	}
	p.mu.Unlock()
	if p.cfg.Debug == nil {
		return
	}
	if severity == "error" || severity == "fatal" {
		p.cfg.Debug("mpv: %s: %s", level, redactURIs(text))
		return
	}
	if p.logLevel() != "warn" {
		p.cfg.Debug("mpv: %s: %s%s", level, prefix, redactURIs(text))
	}
}

// recordLoadSignal keeps the HTTP status and the last few warning/error lines
// of this load. Caller holds p.mu.
func (p *Player) recordLoadSignal(text string) {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return
	}
	if match := httpStatusPattern.FindStringSubmatch(trimmed); match != nil && p.loadStatus == 0 {
		if status, err := strconv.Atoi(match[1]); err == nil {
			p.loadStatus = status
		}
	}
	if len(p.loadLog) >= 8 {
		p.loadLog = p.loadLog[1:]
	}
	p.loadLog = append(p.loadLog, trimmed)
}

func (p *Player) onHook(event *cEvent) {
	if event.Data == nil {
		return
	}
	hook := (*cEventHook)(event.Data)
	name := goString(unsafe.Pointer(hook.Name))
	if name == "on_load" {
		p.applyHeader()
	}
	if rc := p.lib.hookContinue(p.ctx, hook.ID); rc < 0 && p.cfg.Debug != nil {
		p.cfg.Debug("mpv: hook_continue: %s", p.lib.ErrorString(rc))
	}
}

// applyHeader sets http-header-fields for the file mpv is about to open. The
// per-file loadfile options the plan first assumed do not exist on 0.36
// (spike §6.1); this hook is media_kit's own approach on the same library.
//
// The property is global, so it is set to the value of the file being opened
// even when that value is empty: leaving a previous track's Authorization in
// place would send one source's credentials to the next URL.
func (p *Player) applyHeader() {
	path, ok := p.propString("path")
	if !ok {
		return
	}
	p.mu.Lock()
	header := p.header[path]
	applied := p.headerApplied
	p.headerApplied = header
	p.mu.Unlock()
	if applied == header {
		return
	}
	if err := p.setPropertyString("http-header-fields", header); err != nil {
		if p.cfg.Debug != nil {
			p.cfg.Debug("mpv: set http-header-fields for %s: %v", path, err)
		}
		return
	}
	if p.cfg.Debug != nil {
		if header == "" {
			p.cfg.Debug("mpv: cleared per-track headers for %s", redactURIs(path))
			return
		}
		// Header *names* only: an Authorization or Cookie value in a log file
		// would be a stored credential (M3 §3.4). The values themselves are the
		// engine's business, not the log's.
		p.cfg.Debug("mpv: per-track headers [%s] for %s", headerFieldNames(header), redactURIs(path))
	}
}

func (p *Player) onProperty(event *cEvent) {
	if event.Data == nil {
		return
	}
	property := (*cEventProperty)(event.Data)
	name := propNames[event.ReplyUserdata]
	p.mu.Lock()
	significant := false
	switch property.Format {
	case FormatFlag:
		value := *(*int32)(property.Data) != 0
		switch name {
		case "pause":
			significant = p.paused != value
			p.paused = value
		case "idle-active":
			significant = p.idle != value
			p.idle = value
		case "paused-for-cache":
			p.pausedForCache = value
		}
	case FormatDouble:
		value := *(*float64)(property.Data)
		switch name {
		case "playback-time":
			p.position = value
		case "duration":
			significant = p.duration != value
			p.duration = value
		case "volume":
			p.volume = value
		case "speed":
			significant = p.speed != value
			p.speed = value
		case "demuxer-cache-time":
			p.cacheTime = value
		}
	case FormatInt64:
		value := *(*int64)(property.Data)
		switch name {
		case "cache-buffering-state":
			p.cacheBuffering = value
		case "playlist-pos":
			if value >= 0 && int(value) != p.index {
				p.index = int(value)
				significant = true
			}
		}
	case FormatString:
		// data is char** for MPV_FORMAT_STRING, not char*.
		value := goString(*(*unsafe.Pointer)(property.Data))
		if name == "path" {
			significant = p.path != value
			p.path = value
			if value != "" {
				p.idle = false
				// playlist-pos does not move reliably when a paused queue is
				// replayed with playlist-play-index; the path does, and it is
				// what decides which track is playing.
				for i := range p.items {
					if p.items[i].URI == value {
						if p.index != i {
							p.index = i
							significant = true
						}
						break
					}
				}
			}
		}
	}
	p.mu.Unlock()
	if significant {
		p.forcePublish()
		return
	}
	p.publish(false)
}

func (p *Player) onStartFile() {
	p.mu.Lock()
	p.position = 0
	p.duration = 0
	p.cacheTime = 0
	p.completed = false
	p.needsReload = false
	p.loadStatus = 0
	p.loadLog = p.loadLog[:0]
	p.lastPos = 0
	p.mu.Unlock()
	p.forcePublish()
}

func (p *Player) onFileLoaded() {
	p.mu.Lock()
	p.filesLoaded++
	p.failure = nil
	p.needsReload = false
	p.mu.Unlock()
	p.forcePublish()
}

func (p *Player) onEndFile(event *cEvent) {
	if event.Data == nil {
		return
	}
	end := (*cEventEndFile)(event.Data)
	p.mu.Lock()
	switch end.Reason {
	case EndFileError:
		detail := p.lib.ErrorString(end.Error)
		if p.lastError != "" {
			detail += ": " + p.lastError
		}
		if p.failure == nil {
			uri := p.path
			if uri == "" && p.index >= 0 && p.index < len(p.items) {
				uri = p.items[p.index].URI
			}
			p.failure = loadFailure(uri, detail, p.loadStatus, strings.Join(p.loadLog, " | "))
		}
		p.needsReload = true
		p.completed = false
	case EndFileEOF:
		// The last entry ending is the end of the queue. eof-reached alone
		// fires between gapless entries too, so the index is the decisive
		// fact; idle-active is not reliable with idle=yes on this build.
		if p.index >= 0 && p.index >= len(p.items)-1 {
			p.completed = true
		}
	}
	p.mu.Unlock()
	if p.cfg.Debug != nil {
		p.cfg.Debug("mpv: end-file reason=%d err=%d", end.Reason, end.Error)
	}
	p.publish(true)
}

// publish writes a snapshot to subscribers, at most every 50 ms unless force.
func (p *Player) publish(force bool) {
	p.mu.Lock()
	now := time.Now()
	if !force && now.Sub(p.lastPublish) < 50*time.Millisecond {
		p.dirty = true
		p.mu.Unlock()
		return
	}
	snapshot := p.snapshotLocked()
	p.lastPublish = now
	p.dirty = false
	subs := make([]chan Snapshot, 0, len(p.subs))
	for _, ch := range p.subs {
		subs = append(subs, ch)
	}
	p.mu.Unlock()
	for _, ch := range subs {
		select {
		case ch <- snapshot:
		default:
			// A slow consumer can always read Snapshot(); dropping an
			// intermediate position beats blocking mpv's event loop.
		}
	}
	if p.cfg.Debug != nil && force {
		p.cfg.Debug("mpv: state %s playing=%v pos=%.2f dur=%.2f index=%d path=%s",
			snapshot.Processing, snapshot.Playing, snapshot.Position.Seconds(),
			snapshot.Duration.Seconds(), snapshot.Index, redactURIs(snapshot.Path))
	}
}

func (p *Player) forcePublish() { p.publish(true) }

func (p *Player) snapshotLocked() Snapshot {
	// The only evidence a failure is over is audible progress: mpv still
	// reports the old duration and may still report playing=true after a
	// failed load (media_kit_engine.dart learned this the hard way).
	if p.failure != nil && !p.paused && p.position > p.lastPos {
		p.failure = nil
	}
	p.lastPos = p.position

	buffered := p.position + p.cacheTime
	if p.duration > 0 && buffered > p.duration {
		buffered = p.duration
	}
	if buffered < p.position {
		buffered = p.position
	}
	snapshot := Snapshot{
		At:        time.Now(),
		Position:  secondsDuration(p.position),
		Duration:  secondsDuration(p.duration),
		Buffered:  secondsDuration(buffered),
		Index:     p.index,
		Rate:      p.speed,
		Volume:    p.volume / 100,
		Path:      p.path,
		Paused:    p.paused,
		Underruns: p.underruns,
		Failure:   p.failure,
	}
	// completed is set only by end-file(EOF) on the last entry. It is
	// deliberately not inferred from eof-reached/idle-active: eof-reached is
	// true for a moment between gapless entries too, and idle-active never
	// becomes true on this build at the end of the playlist (M1 record §12.2).
	snapshot.Playing = !p.paused && !p.idle && !p.completed && p.path != "" && p.failure == nil
	switch {
	case len(p.items) == 0:
		snapshot.Processing = Idle
	case p.completed:
		snapshot.Processing = Completed
		snapshot.Playing = false
	case p.pausedForCache || (p.cacheBuffering > 0 && p.cacheBuffering < 100):
		snapshot.Processing = Buffering
	case p.path == "":
		snapshot.Processing = Loading
	default:
		// duration == 0 is not loading: remote direct links often have no
		// Content-Length, and a spinner for a playing song looks broken.
		snapshot.Processing = Ready
	}
	return snapshot
}

// Snapshot returns the current state.
func (p *Player) Snapshot() Snapshot {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.snapshotLocked()
}

// Subscribe returns a snapshot stream and a cancel function.
func (p *Player) Subscribe() (<-chan Snapshot, func()) {
	ch := make(chan Snapshot, 8)
	p.mu.Lock()
	id := p.nextID
	p.nextID++
	p.subs[id] = ch
	p.mu.Unlock()
	return ch, func() {
		p.mu.Lock()
		delete(p.subs, id)
		p.mu.Unlock()
	}
}

// Items returns the playlist as last set.
func (p *Player) Items() []Item {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]Item(nil), p.items...)
}

// Underruns is the count of audio underruns since start, used by acceptance.
func (p *Player) Underruns() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.underruns
}

// AOInits is how many times the audio output was (re)initialized. One across
// an album is the structural half of the gapless evidence: the device stream
// was never torn down between tracks.
func (p *Player) AOInits() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.aoInits
}

// FilesLoaded is how many files mpv has finished loading.
func (p *Player) FilesLoaded() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.filesLoaded
}

// Index returns the engine's current playlist index (-1 when none).
func (p *Player) Index() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.index
}

// SetQueue replaces the playlist without starting playback.
//
// stop → playlist-clear → append is not optional: playlist-clear keeps the
// item that is currently playing (spike §6.2), so without the stop the new
// queue's first entry would still be the previous song.
func (p *Player) SetQueue(items []Item, start int) error {
	if len(items) == 0 {
		return errors.New("mpv: empty queue")
	}
	if start < 0 || start >= len(items) {
		return fmt.Errorf("mpv: start %d outside a queue of %d", start, len(items))
	}
	// Pause before loading: SetQueue must not make a sound on its own.
	if err := p.setPropertyString("pause", "yes"); err != nil {
		return err
	}
	if err := p.Command("stop"); err != nil && p.cfg.Debug != nil {
		p.cfg.Debug("mpv: stop: %v", err)
	}
	if err := p.Command("playlist-clear"); err != nil {
		return err
	}
	p.mu.Lock()
	p.items = append([]Item(nil), items...)
	p.index = start
	p.path = items[start].URI
	p.position = 0
	p.duration = 0
	p.completed = false
	p.failure = nil
	p.lastError = ""
	p.lastPos = 0
	p.header = map[string]string{}
	for _, item := range items {
		if header := headerValue(item.Headers); header != "" {
			p.header[item.URI] = header
		}
	}
	p.mu.Unlock()
	for _, item := range items {
		if err := p.Command("loadfile", item.URI, "append"); err != nil {
			p.forcePublish()
			return err
		}
	}
	if err := p.Command("playlist-play-index", strconv.Itoa(start)); err != nil {
		p.forcePublish()
		return err
	}
	if err := p.setPropertyString("pause", "yes"); err != nil {
		return err
	}
	p.forcePublish()
	return nil
}

// Append adds one item without interrupting playback.
func (p *Player) Append(item Item) error {
	p.mu.Lock()
	p.items = append(p.items, item)
	if header := headerValue(item.Headers); header != "" {
		if p.header == nil {
			p.header = map[string]string{}
		}
		p.header[item.URI] = header
	}
	p.mu.Unlock()
	if err := p.Command("loadfile", item.URI, "append"); err != nil {
		return err
	}
	return nil
}

// headerFieldNames lists the names of an http-header-fields value ("A: 1,B:
// 2"), so a debug line can say what was applied without printing a credential.
func headerFieldNames(header string) string {
	parts := strings.Split(header, ",")
	names := make([]string, 0, len(parts))
	for _, part := range parts {
		name, _, found := strings.Cut(part, ":")
		name = strings.TrimSpace(name)
		if !found || name == "" {
			continue
		}
		names = append(names, name)
	}
	return strings.Join(names, ",")
}

func headerValue(headers map[string]string) string {
	if len(headers) == 0 {
		return ""
	}
	parts := make([]string, 0, len(headers))
	for _, key := range sortedMapKeys(headers) {
		parts = append(parts, key+": "+headers[key])
	}
	return strings.Join(parts, ",")
}

func sortedMapKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// Play unpauses. A queue stopped at its end, or an entry whose last load
// failed, is restarted at the current index first: mpv ignores pause=no when
// it sits idle, which is the dead play button users hit after a dropped
// network (M2 acceptance: the failure must be recoverable).
func (p *Player) Play() error {
	p.mu.Lock()
	reload := p.needsReload || p.completed || p.idle
	index := p.index
	hasItems := len(p.items) > 0
	if reload {
		p.completed = false
		p.needsReload = false
	}
	p.mu.Unlock()
	if reload && hasItems && index >= 0 {
		if err := p.Command("playlist-play-index", strconv.Itoa(index)); err != nil && p.cfg.Debug != nil {
			p.cfg.Debug("mpv: replay index %d: %v", index, err)
		}
	}
	return p.setPropertyString("pause", "no")
}

// Pause pauses playback.
func (p *Player) Pause() error { return p.setPropertyString("pause", "yes") }

// Seek jumps to an absolute position.
func (p *Player) Seek(position time.Duration) error {
	if position < 0 {
		position = 0
	}
	return p.Command("seek", fmt.Sprintf("%.3f", position.Seconds()), "absolute")
}

// SetRate sets the playback speed.
func (p *Player) SetRate(rate float64) error {
	if rate <= 0 {
		rate = 1
	}
	return p.setPropertyString("speed", fmt.Sprintf("%.3f", rate))
}

// SetVolume takes 0..1 and maps it onto mpv's 0..100.
func (p *Player) SetVolume(volume float64) error {
	if volume < 0 {
		volume = 0
	}
	if volume > 1 {
		volume = 1
	}
	return p.setPropertyString("volume", fmt.Sprintf("%.2f", volume*100))
}

// SetRepeatOne makes mpv loop the current file itself (seamless); repeat-all
// and repeat-off leave the looping to the controller (plan §4.5).
func (p *Player) SetRepeatOne(on bool) error {
	if on {
		return p.setPropertyString("loop-file", "inf")
	}
	return p.setPropertyString("loop-file", "no")
}

// Next advances one playlist entry.
func (p *Player) Next() error { return p.Command("playlist-next") }

// Prev goes back one playlist entry.
func (p *Player) Prev() error { return p.Command("playlist-prev") }

// PlayIndex selects an entry, keeping the paused state.
func (p *Player) PlayIndex(index int) error {
	p.mu.Lock()
	if index >= 0 && index < len(p.items) {
		p.index = index
	}
	p.mu.Unlock()
	return p.Command("playlist-play-index", strconv.Itoa(index))
}

// Command sends one mpv command.
func (p *Player) Command(args ...string) error {
	pointers := make([]*byte, len(args)+1)
	for i, arg := range args {
		pointers[i] = bp(arg)
	}
	rc := p.lib.command(p.ctx, &pointers[0])
	runtime.KeepAlive(args)
	runtime.KeepAlive(pointers)
	if rc < 0 {
		return fmt.Errorf("mpv: %v: %s", args, p.lib.ErrorString(rc))
	}
	return nil
}

func (p *Player) setPropertyString(name, value string) error {
	rc := p.lib.setPropertyString(p.ctx, bp(name), bp(value))
	runtime.KeepAlive(name)
	runtime.KeepAlive(value)
	if rc < 0 {
		return fmt.Errorf("mpv: set %s=%s: %s", name, value, p.lib.ErrorString(rc))
	}
	return nil
}

func (p *Player) propString(name string) (string, bool) {
	ptr := p.lib.getPropertyString(p.ctx, bp(name))
	runtime.KeepAlive(name)
	if ptr == nil {
		return "", false
	}
	value := goString(ptr)
	p.lib.free(ptr)
	return value, true
}

// Close stops the event loop and destroys the core. It is safe twice.
func (p *Player) Close() error {
	p.mu.Lock()
	if p.closed {
		err := p.closeErr
		p.mu.Unlock()
		return err
	}
	p.closed = true
	p.mu.Unlock()
	close(p.done)
	p.wg.Wait()
	p.lib.terminateDestroy(p.ctx)
	p.mu.Lock()
	for _, ch := range p.subs {
		close(ch)
	}
	p.subs = map[int]chan Snapshot{}
	p.mu.Unlock()
	return nil
}

func secondsDuration(seconds float64) time.Duration {
	if seconds <= 0 {
		return 0
	}
	return time.Duration(seconds * float64(time.Second))
}

// ClientAPIVersion reports the loaded library's client API version.
func (p *Player) ClientAPIVersion() (major, minor int) {
	version := p.lib.ClientAPIVersion()
	return int(version >> 16), int(version & 0xffff)
}
