// Package mpv 用 purego 在进程内 dlopen libmpv（无 cgo），只暴露听屿 spike 需要的
// 那一小部分 C API（mpv/client.h，mpv 0.36.0 / client API 2.1）。
//
// 关键事实（实测得出，勿想当然）：
//   - 必须用 RTLD_LAZY：media_kit 随包的 Mpv.framework 是 audio-only 构建，对 libass
//     的符号未解析（osd_libass.c 的 _ass_*），RTLD_NOW 会直接 dlopen 失败。
//   - 依赖的 Av*/Sw* framework 是 @rpath 引用，需要可执行文件带 LC_RPATH 指向
//     @executable_path/../Frameworks（见 scripts/bundle.sh）。
//   - mpv_event/mpv_event_property/mpv_event_end_file 的布局按 client.h 对齐，
//     layout_test.go 里有断言。
package mpv

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
)

// MPV_FORMAT_*
const (
	FormatNone      = 0
	FormatString    = 1
	FormatOSDString = 2
	FormatFlag      = 3
	FormatInt64     = 4
	FormatDouble    = 5
	FormatNode      = 6
)

// mpv_event_id（client.h 0.36；**不要**用这些数字做 switch，事件名以
// mpv_event_name() 返回的字符串为准，见 player.loop —— 数字曾经把
// playback-restart 当成 property-change，白查了半天。）
const (
	EvNone            = 0
	EvShutdown        = 1
	EvLogMessage      = 2
	EvStartFile       = 6
	EvEndFile         = 7
	EvFileLoaded      = 8
	EvIdle            = 11
	EvTick            = 14
	EvClientMessage   = 16
	EvVideoReconfig   = 17
	EvAudioReconfig   = 18
	EvSeek            = 20
	EvPlaybackRestart = 21
	EvPropertyChange  = 22
	EvQueueOverflow   = 24
	EvHook            = 25
)

// mpv_end_file_reason（client.h：**没有 1**，STOP 就是 2）
const (
	EndFileEOF      = 0
	EndFileStop     = 2
	EndFileQuit     = 3
	EndFileError    = 4
	EndFileRedirect = 5
)

// cEvent 是 mpv_event 的 Go 镜像（int32, int32, uint64, void* = 24 字节）。
type cEvent struct {
	EventID       int32
	Error         int32
	ReplyUserdata uint64
	Data          unsafe.Pointer
}

// cEventProperty 是 mpv_event_property 的 Go 镜像（name, format+padding, data = 24 字节）。
type cEventProperty struct {
	Name   *byte
	Format int32
	_      int32
	Data   unsafe.Pointer
}

// cEventEndFile 是 mpv_event_end_file 的 Go 镜像（0.36 / API 1.108 起的字段）。
type cEventEndFile struct {
	Reason                   int32
	Error                    int32
	PlaylistEntryID          int64
	PlaylistInsertID         int64
	PlaylistInsertNumEntries int32
	_                        int32
}

// cEventHook 是 mpv_event_hook 的 Go 镜像（name + id）。
type cEventHook struct {
	Name *byte
	ID   uint64
}

// cEventLogMessage 是 mpv_event_log_message 的 Go 镜像（prefix, level, text, log_level+padding）。
type cEventLogMessage struct {
	Prefix   *byte
	Level    *byte
	Text     *byte
	LogLevel int32
	_        int32
}

// Lib 保存一个已 dlopen 的 libmpv 句柄与函数符号。
type Lib struct {
	handle uintptr

	create            func() unsafe.Pointer
	initialize        func(ctx unsafe.Pointer) int32
	destroy           func(ctx unsafe.Pointer)
	terminateDestroy  func(ctx unsafe.Pointer)
	setOptionString   func(ctx unsafe.Pointer, name, val *byte) int32
	setPropertyString func(ctx unsafe.Pointer, name, val *byte) int32
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

var (
	libOnce sync.Once
	loaded  *Lib
	libErr  error
)

// Load 打开 libmpv 动态库（进程内只做一次；后续调用返回同一句柄）。
func Load(path string) (*Lib, error) {
	libOnce.Do(func() {
		h, err := purego.Dlopen(path, purego.RTLD_LAZY|purego.RTLD_GLOBAL)
		if err != nil {
			libErr = fmt.Errorf("dlopen %s: %w", path, err)
			return
		}
		l := &Lib{handle: h}
		purego.RegisterLibFunc(&l.create, h, "mpv_create")
		purego.RegisterLibFunc(&l.initialize, h, "mpv_initialize")
		purego.RegisterLibFunc(&l.destroy, h, "mpv_destroy")
		purego.RegisterLibFunc(&l.terminateDestroy, h, "mpv_terminate_destroy")
		purego.RegisterLibFunc(&l.setOptionString, h, "mpv_set_option_string")
		purego.RegisterLibFunc(&l.setPropertyString, h, "mpv_set_property_string")
		purego.RegisterLibFunc(&l.setProperty, h, "mpv_set_property")
		purego.RegisterLibFunc(&l.getProperty, h, "mpv_get_property")
		purego.RegisterLibFunc(&l.getPropertyString, h, "mpv_get_property_string")
		purego.RegisterLibFunc(&l.free, h, "mpv_free")
		purego.RegisterLibFunc(&l.command, h, "mpv_command")
		purego.RegisterLibFunc(&l.waitEvent, h, "mpv_wait_event")
		purego.RegisterLibFunc(&l.observeProperty, h, "mpv_observe_property")
		purego.RegisterLibFunc(&l.eventName, h, "mpv_event_name")
		purego.RegisterLibFunc(&l.errorString, h, "mpv_error_string")
		purego.RegisterLibFunc(&l.requestLog, h, "mpv_request_log_messages")
		purego.RegisterLibFunc(&l.hookAdd, h, "mpv_hook_add")
		purego.RegisterLibFunc(&l.hookContinue, h, "mpv_hook_continue")
		purego.RegisterLibFunc(&l.clientAPIVersion, h, "mpv_client_api_version")
		loaded = l
	})
	if libErr != nil {
		return nil, libErr
	}
	return loaded, nil
}

// DefaultLibPath 按优先级找 libmpv：环境变量 MPV_LIB，其次 .app 包内的
// Contents/Frameworks/Mpv.framework（scripts/bundle.sh 打出来的布局）。
func DefaultLibPath() string {
	if p := os.Getenv("MPV_LIB"); p != "" {
		return p
	}
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	cand := filepath.Clean(filepath.Join(filepath.Dir(exe), "..", "Frameworks", "Mpv.framework", "Versions", "A", "Mpv"))
	if st, err := os.Stat(cand); err == nil && !st.IsDir() {
		return cand
	}
	return ""
}

// ClientAPIVersion 返回 (major<<16)|minor。
func (l *Lib) ClientAPIVersion() uint64 { return l.clientAPIVersion() }

// ErrorString 把 mpv 错误码转成可读文本。
func (l *Lib) ErrorString(code int32) string { return goString(l.errorString(code)) }

// EventName 把事件 id 转成名字（名字来自库本身，避免我们猜 id 含义）。
func (l *Lib) EventName(id int32) string { return goString(l.eventName(id)) }

// goString 读取以 NUL 结尾的 C 字符串，并**复制**到 Go 内存：调用方随后
// 释放 C 侧缓冲区（mpv_free）时不能留下悬垂字符串。
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

// bp 把 Go 字符串转成 NUL 结尾的 C 字符串。
func bp(s string) *byte {
	if s == "" {
		return nil
	}
	b := make([]byte, len(s)+1)
	copy(b, s)
	return &b[0]
}
