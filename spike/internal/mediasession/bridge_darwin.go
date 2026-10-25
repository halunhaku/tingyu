//go:build darwin

package mediasession

// The Objective-C runtime bridge: purego.Dlopen the frameworks, resolve
// objc_msgSend once per signature, and wrap Foundation's value classes. No cgo,
// no .m file, no dylib of our own.

import (
	"fmt"
	"runtime"
	"structs"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
)

const (
	pathLibObjC        = "/usr/lib/libobjc.A.dylib"
	pathFoundation     = "/System/Library/Frameworks/Foundation.framework/Foundation"
	pathAppKit         = "/System/Library/Frameworks/AppKit.framework/AppKit"
	pathMediaPlayer    = "/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer"
	pathIOKit          = "/System/Library/Frameworks/IOKit.framework/IOKit"
	pathCoreFoundation = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"

	// MPNowPlayingPlaybackState.
	playbackStatePlaying = 1
	playbackStatePaused  = 2
	playbackStateStopped = 3

	// MPRemoteCommandHandlerStatus.
	commandStatusSuccess = 0

	// MPNowPlayingInfoMediaTypeAudio.
	mediaTypeAudio = 1
)

// cgSize mirrors CoreGraphics' CGSize; the HostLayout marker keeps the Go
// field offsets identical to C without participating in @encode.
type cgSize struct {
	_      structs.HostLayout
	Width  float64
	Height float64
}

// nowPlayingKeys are the MPNowPlayingInfoCenter / MPMediaItem dictionary keys,
// taken from MediaPlayer's exported NSString * constants instead of building
// them by hand.
type nowPlayingKeys struct {
	title       objc.ID
	artist      objc.ID
	album       objc.ID
	duration    objc.ID
	artwork     objc.ID
	elapsed     objc.ID
	rate        objc.ID
	defaultRate objc.ID
	mediaType   objc.ID
	externalID  objc.ID
}

var (
	fwOnce sync.Once
	fwErr  error

	mediaPlayerHandle uintptr
	keys              nowPlayingKeys

	// objc_msgSend per return/argument shape. Declaring a variant with the
	// wrong types silently yields garbage instead of failing, so each one is
	// written out and exercised by the spike's --verify round trip.
	msgID          func(objc.ID, objc.SEL) objc.ID
	msgIDID        func(objc.ID, objc.SEL, objc.ID) objc.ID
	msgIDCStr      func(objc.ID, objc.SEL, *byte) objc.ID
	msgIDBlock     func(objc.ID, objc.SEL, objc.Block) objc.ID
	msgIDSizeBlock func(objc.ID, objc.SEL, cgSize, objc.Block) objc.ID
	msgIDDouble    func(objc.ID, objc.SEL, float64) objc.ID
	msgIDUint      func(objc.ID, objc.SEL, uintptr) objc.ID
	msgIDOptions   func(objc.ID, objc.SEL, uint64, objc.ID) objc.ID
	msgDouble      func(objc.ID, objc.SEL) float64
	msgInt64       func(objc.ID, objc.SEL) int64
	msgBool        func(objc.ID, objc.SEL) bool
	msgBoolID      func(objc.ID, objc.SEL, objc.ID) bool
	msgString      func(objc.ID, objc.SEL) string
	msgSize        func(objc.ID, objc.SEL) cgSize
	msgVoid        func(objc.ID, objc.SEL)
	msgVoidID      func(objc.ID, objc.SEL, objc.ID)
	msgVoidIDID    func(objc.ID, objc.SEL, objc.ID, objc.ID)
	msgVoidInt64   func(objc.ID, objc.SEL, int64)
	msgVoidBool    func(objc.ID, objc.SEL, bool)

	selMu sync.Mutex
	sels  = map[string]objc.SEL{}
)

// sel returns the cached selector of name. objc.RegisterName takes the global
// Objective-C lock, so it must not run on every message.
func sel(name string) objc.SEL {
	selMu.Lock()
	defer selMu.Unlock()
	s, ok := sels[name]
	if !ok {
		s = objc.RegisterName(name)
		sels[name] = s
	}
	return s
}

// class returns the class object of name, or 0 when the owning framework has
// not been loaded.
func class(name string) objc.ID { return objc.ID(objc.GetClass(name)) }

// loadFrameworks loads the frameworks and resolves the message-send variants.
// Idempotent; failures are cached.
func loadFrameworks() error {
	fwOnce.Do(func() { fwErr = initFrameworks() })
	return fwErr
}

func initFrameworks() error {
	// RTLD_LAZY, not RTLD_NOW: this process also hosts libmpv, which carries
	// unresolved libass symbols. RTLD_NOW would try to bind every undefined
	// symbol of every loaded image and fail.
	handles := make(map[string]uintptr, 4)
	for _, path := range []string{pathLibObjC, pathFoundation, pathAppKit, pathMediaPlayer} {
		h, err := purego.Dlopen(path, purego.RTLD_LAZY|purego.RTLD_GLOBAL)
		if err != nil {
			return fmt.Errorf("mediasession: dlopen %s: %w", path, err)
		}
		handles[path] = h
	}
	mediaPlayerHandle = handles[pathMediaPlayer]

	objcLib := handles[pathLibObjC]
	msgSend, err := purego.Dlsym(objcLib, "objc_msgSend")
	if err != nil {
		return fmt.Errorf("mediasession: dlsym objc_msgSend: %w", err)
	}
	for _, fn := range []any{
		&msgID, &msgIDID, &msgIDCStr, &msgIDBlock, &msgIDSizeBlock, &msgIDDouble,
		&msgIDUint, &msgIDOptions, &msgDouble, &msgInt64, &msgBool, &msgBoolID,
		&msgString, &msgSize, &msgVoid, &msgVoidID, &msgVoidIDID, &msgVoidInt64,
		&msgVoidBool,
	} {
		purego.RegisterFunc(fn, msgSend)
	}

	targets := map[string]*objc.ID{
		"MPMediaItemPropertyTitle":                          &keys.title,
		"MPMediaItemPropertyArtist":                         &keys.artist,
		"MPMediaItemPropertyAlbumTitle":                     &keys.album,
		"MPMediaItemPropertyPlaybackDuration":               &keys.duration,
		"MPMediaItemPropertyArtwork":                        &keys.artwork,
		"MPNowPlayingInfoPropertyElapsedPlaybackTime":       &keys.elapsed,
		"MPNowPlayingInfoPropertyPlaybackRate":              &keys.rate,
		"MPNowPlayingInfoPropertyDefaultPlaybackRate":       &keys.defaultRate,
		"MPNowPlayingInfoPropertyMediaType":                 &keys.mediaType,
		"MPNowPlayingInfoPropertyExternalContentIdentifier": &keys.externalID,
	}
	for name, target := range targets {
		*target, err = frameworkString(mediaPlayerHandle, name)
		if err != nil {
			return fmt.Errorf("mediasession: %w", err)
		}
	}
	for _, name := range []string{"MPNowPlayingInfoCenter", "MPRemoteCommandCenter", "MPMediaItemArtwork"} {
		if class(name) == 0 {
			return fmt.Errorf("mediasession: MediaPlayer has no %s", name)
		}
	}
	return nil
}

// dlsymPtr reads the pointer stored at a dlsym'd symbol address, i.e. the
// value of an exported `Some * const`.
func dlsymPtr(handle uintptr, name string) (unsafe.Pointer, error) {
	addr, err := purego.Dlsym(handle, name)
	if err != nil {
		return nil, err
	}
	// Converting addr to unsafe.Pointer directly trips go vet; round-trip
	// through &addr instead.
	return *(*unsafe.Pointer)(unsafe.Pointer(&addr)), nil
}

// frameworkString reads an exported `NSString * const` out of a framework.
func frameworkString(handle uintptr, name string) (objc.ID, error) {
	ptr, err := dlsymPtr(handle, name)
	if err != nil {
		return 0, fmt.Errorf("dlsym %s: %w", name, err)
	}
	return *(*objc.ID)(ptr), nil
}

// nsString returns an autoreleased NSString. It must run inside an autorelease
// pool, i.e. inside mainq.Post.
func nsString(s string) objc.ID {
	b := append([]byte(s), 0)
	str := msgIDCStr(class("NSString"), sel("stringWithUTF8String:"), &b[0])
	runtime.KeepAlive(b)
	return str
}

// nsNumber returns an autoreleased NSNumber holding v.
func nsNumber(v float64) objc.ID {
	return msgIDDouble(class("NSNumber"), sel("numberWithDouble:"), v)
}

// nsNumberUint returns an autoreleased NSNumber holding v as NSUInteger.
func nsNumberUint(v uintptr) objc.ID {
	return msgIDUint(class("NSNumber"), sel("numberWithUnsignedInteger:"), v)
}

// nsStringOf reads an NSString object as a Go string.
func nsStringOf(v objc.ID) (string, bool) {
	if v == 0 || !msgBoolID(v, sel("isKindOfClass:"), class("NSString")) {
		return "", false
	}
	return msgString(v, sel("UTF8String")), true
}

// nsFloatOf reads an NSNumber object as a float64.
func nsFloatOf(v objc.ID) (float64, bool) {
	if v == 0 || !msgBoolID(v, sel("isKindOfClass:"), class("NSNumber")) {
		return 0, false
	}
	return msgDouble(v, sel("doubleValue")), true
}
