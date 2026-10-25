// Package mpv binds the libmpv C API in-process through purego, with no cgo.
//
// The binding is deliberately narrow: what a player needs to load files, keep a
// playlist, observe the properties a UI shows, and receive end-of-file and
// error events. It mirrors the parts of mpv/client.h the spike exercised
// (client API 2.1, mpv 0.36), and records the layout facts that cost the spike
// debugging time:
//
//   - RTLD_LAZY is mandatory: media_kit's Mpv.framework is an audio-only build
//     with unresolved libass symbols, so RTLD_NOW fails to load.
//   - Event ids are never switched on; names come from mpv_event_name.
//   - MPV_FORMAT_STRING's data is char**, not char*.
//   - mpv_get_property_string returns memory owned by mpv; copy before free.
package mpv

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
)

// MPV_FORMAT_* values.
const (
	FormatNone   = 0
	FormatString = 1
	FormatFlag   = 3
	FormatInt64  = 4
	FormatDouble = 5
)

// mpv_end_file_reason (client.h: there is no 1; STOP is 2).
const (
	EndFileEOF      = 0
	EndFileStop     = 2
	EndFileQuit     = 3
	EndFileError    = 4
	EndFileRedirect = 5
)

// cEvent mirrors mpv_event (int32, int32, uint64, void* = 24 bytes).
type cEvent struct {
	EventID       int32
	Error         int32
	ReplyUserdata uint64
	Data          unsafe.Pointer
}

// cEventProperty mirrors mpv_event_property (name, format+padding, data).
type cEventProperty struct {
	Name   *byte
	Format int32
	_      int32
	Data   unsafe.Pointer
}

// cEventEndFile mirrors mpv_event_end_file for 0.36.
type cEventEndFile struct {
	Reason                   int32
	Error                    int32
	PlaylistEntryID          int64
	PlaylistInsertID         int64
	PlaylistInsertNumEntries int32
	_                        int32
}

// cEventHook mirrors mpv_event_hook.
type cEventHook struct {
	Name *byte
	ID   uint64
}

// cEventLogMessage mirrors mpv_event_log_message.
type cEventLogMessage struct {
	Prefix   *byte
	Level    *byte
	Text     *byte
	LogLevel int32
	_        int32
}

// Lib is a loaded libmpv and its symbols.
type Lib struct {
	handle uintptr

	create            func() unsafe.Pointer
	initialize        func(ctx unsafe.Pointer) int32
	destroy           func(ctx unsafe.Pointer)
	terminateDestroy  func(ctx unsafe.Pointer)
	setOptionString   func(ctx unsafe.Pointer, name, value *byte) int32
	setPropertyString func(ctx unsafe.Pointer, name, value *byte) int32
	setProperty       func(ctx unsafe.Pointer, name *byte, format int32, data unsafe.Pointer) int32
	getProperty       func(ctx unsafe.Pointer, name *byte, format int32, data unsafe.Pointer) int32
	getPropertyString func(ctx unsafe.Pointer, name *byte) unsafe.Pointer
	free              func(ptr unsafe.Pointer)
	command           func(ctx unsafe.Pointer, args **byte) int32
	waitEvent         func(ctx unsafe.Pointer, timeout float64) unsafe.Pointer
	observeProperty   func(ctx unsafe.Pointer, userdata uint64, name *byte, format int32) int32
	eventName         func(id int32) unsafe.Pointer
	errorString       func(code int32) unsafe.Pointer
	requestLog        func(ctx unsafe.Pointer, level *byte) int32
	hookAdd           func(ctx unsafe.Pointer, userdata uint64, name *byte, priority int32) int32
	hookContinue      func(ctx unsafe.Pointer, id uint64) int32
	clientAPIVersion  func() uint64
}

// Open loads libmpv at path. A process may load several handles, but each
// player creates its own core; tests load one.
func Open(path string) (*Lib, error) {
	if path == "" {
		return nil, fmt.Errorf("mpv: no libmpv path (set MPV_LIB or bundle Mpv.framework)")
	}
	handle, err := purego.Dlopen(path, purego.RTLD_LAZY|purego.RTLD_GLOBAL)
	if err != nil {
		return nil, fmt.Errorf("mpv: dlopen %s: %w", path, err)
	}
	lib := &Lib{handle: handle}
	purego.RegisterLibFunc(&lib.create, handle, "mpv_create")
	purego.RegisterLibFunc(&lib.initialize, handle, "mpv_initialize")
	purego.RegisterLibFunc(&lib.destroy, handle, "mpv_destroy")
	purego.RegisterLibFunc(&lib.terminateDestroy, handle, "mpv_terminate_destroy")
	purego.RegisterLibFunc(&lib.setOptionString, handle, "mpv_set_option_string")
	purego.RegisterLibFunc(&lib.setPropertyString, handle, "mpv_set_property_string")
	purego.RegisterLibFunc(&lib.setProperty, handle, "mpv_set_property")
	purego.RegisterLibFunc(&lib.getProperty, handle, "mpv_get_property")
	purego.RegisterLibFunc(&lib.getPropertyString, handle, "mpv_get_property_string")
	purego.RegisterLibFunc(&lib.free, handle, "mpv_free")
	purego.RegisterLibFunc(&lib.command, handle, "mpv_command")
	purego.RegisterLibFunc(&lib.waitEvent, handle, "mpv_wait_event")
	purego.RegisterLibFunc(&lib.observeProperty, handle, "mpv_observe_property")
	purego.RegisterLibFunc(&lib.eventName, handle, "mpv_event_name")
	purego.RegisterLibFunc(&lib.errorString, handle, "mpv_error_string")
	purego.RegisterLibFunc(&lib.requestLog, handle, "mpv_request_log_messages")
	purego.RegisterLibFunc(&lib.hookAdd, handle, "mpv_hook_add")
	purego.RegisterLibFunc(&lib.hookContinue, handle, "mpv_hook_continue")
	purego.RegisterLibFunc(&lib.clientAPIVersion, handle, "mpv_client_api_version")
	return lib, nil
}

// LibraryPath resolves libmpv: MPV_LIB, then the app bundle's
// Contents/Frameworks, then (development only) the media_kit pub cache that
// ships the same LGPL build the Flutter client distributes.
func LibraryPath() string {
	if path := os.Getenv("MPV_LIB"); path != "" {
		return path
	}
	if exe, err := os.Executable(); err == nil {
		bundled := filepath.Join(filepath.Dir(exe), "..", "Frameworks", "Mpv.framework", "Versions", "A", "Mpv")
		if info, err := os.Stat(bundled); err == nil && !info.IsDir() {
			return bundled
		}
	}
	return devLibraryPath()
}

// devLibraryPath finds the newest media_kit_libs_macos_audio in the pub cache.
// It is a development fallback: the binary still needs an LC_RPATH or the
// frameworks next to it (scripts/bundle.sh), and a signed binary ignores
// DYLD_FRAMEWORK_PATH.
func devLibraryPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	pattern := filepath.Join(home, ".pub-cache", "hosted", "pub.dev", "media_kit_libs_macos_audio-*", "macos", "Frameworks", "Mpv.framework", "Versions", "A", "Mpv")
	matches, err := filepath.Glob(pattern)
	if err != nil || len(matches) == 0 {
		return ""
	}
	sort.Strings(matches)
	return matches[len(matches)-1]
}

// ClientAPIVersion returns (major<<16)|minor.
func (l *Lib) ClientAPIVersion() uint64 { return l.clientAPIVersion() }

// ErrorString names an mpv error code.
func (l *Lib) ErrorString(code int32) string { return goString(l.errorString(code)) }

// EventName names an event id using the library's own table.
func (l *Lib) EventName(id int32) string { return goString(l.eventName(id)) }

// goString copies a NUL-terminated C string into Go memory.
func goString(p unsafe.Pointer) string {
	if p == nil {
		return ""
	}
	n := 0
	for *(*byte)(unsafe.Add(p, n)) != 0 {
		n++
		if n > 1<<20 {
			break
		}
	}
	return string(unsafe.Slice((*byte)(p), n))
}

// bp converts a Go string to a NUL-terminated C string. The returned pointer
// is only valid while the caller keeps the original slice alive
// (runtime.KeepAlive at the call site).
func bp(s string) *byte {
	if s == "" {
		return nil
	}
	b := make([]byte, len(s)+1)
	copy(b, s)
	return &b[0]
}

var (
	loadMu sync.Mutex
	loaded = map[string]*Lib{}
)

// Load returns a cached Lib for path, so repeated engine creation in tests
// does not dlopen the same image again.
func Load(path string) (*Lib, error) {
	loadMu.Lock()
	defer loadMu.Unlock()
	if lib, ok := loaded[path]; ok {
		return lib, nil
	}
	lib, err := Open(path)
	if err != nil {
		return nil, err
	}
	loaded[path] = lib
	return lib, nil
}
