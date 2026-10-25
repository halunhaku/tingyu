package mpv

import (
	"testing"
	"time"
	"unsafe"
)

// 布局断言：这些数字必须与 mpv/client.h（0.36.0）一致，否则事件解析会把
// 字段读串，表现为"偶发崩溃/垃圾时间戳"，且极难定位（方案 §4.3 的放弃条件之一）。
func TestStructLayout(t *testing.T) {
	cases := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"mpv_event", unsafe.Sizeof(cEvent{}), 24},
		{"mpv_event_property", unsafe.Sizeof(cEventProperty{}), 24},
		{"mpv_event_end_file", unsafe.Sizeof(cEventEndFile{}), 32},
		{"mpv_event_log_message", unsafe.Sizeof(cEventLogMessage{}), 32},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s size = %d, want %d", c.name, c.got, c.want)
		}
	}
	if off := unsafe.Offsetof(cEvent{}.Data); off != 16 {
		t.Errorf("mpv_event.data offset = %d, want 16", off)
	}
	if off := unsafe.Offsetof(cEventProperty{}.Data); off != 16 {
		t.Errorf("mpv_event_property.data offset = %d, want 16", off)
	}
	if off := unsafe.Offsetof(cEventEndFile{}.PlaylistEntryID); off != 8 {
		t.Errorf("mpv_event_end_file.playlist_entry_id offset = %d, want 8", off)
	}
}

func TestOptionString(t *testing.T) {
	got := optionString(map[string]string{
		"http-header-fields": "Authorization: Basic xyz",
		"referrer":           "https://example.com/",
	})
	want := "http-header-fields=Authorization: Basic xyz,referrer=https://example.com/"
	if got != want {
		t.Fatalf("optionString = %q, want %q", got, want)
	}
	if optionString(nil) != "" {
		t.Fatal("empty options 应返回空串，否则会下发 4 参数 loadfile")
	}
}

// smoke：真的 dlopen + initialize；没有 MPV_LIB 或库里没有 libmpv 时跳过。
func TestSmokeCreate(t *testing.T) {
	libPath := DefaultLibPath()
	if libPath == "" {
		t.Skip("找不到 libmpv（MPV_LIB 未设且不在 .app 布局内），跳过 dlopen 冒烟")
	}
	lib, err := Load(libPath)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if v := lib.ClientAPIVersion(); v>>16 != 2 {
		t.Fatalf("client api version = %#x，期望 2.x", v)
	}
	p, err := New(lib, Config{})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer p.Close()
	if got := p.Snapshot(); !got.IdleActive {
		t.Logf("idle-active=%v（新 core 上不保证立刻为 true，只做记录）", got.IdleActive)
	}
	if _, ok := p.PropString("mpv-version"); !ok {
		t.Error("读不到 mpv-version")
	}
	time.Sleep(50 * time.Millisecond)
}
