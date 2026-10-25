//go:build darwin

package app

import (
	"encoding/binary"
	"os"
	"sync"
	"time"
	"unsafe"

	"github.com/ebitengine/purego"
)

var processStartFunc struct {
	once sync.Once
	fn   uintptr
}

// processStart returns when this process started, read from the kernel
// with proc_pid_rusage(RUSAGE_INFO_V2), whose ri_proc_start_abstime is a
// Mach absolute time, converted with mach_timebase_info. No cgo: purego
// calls libproc directly, the same way the M1 playback kernel will call
// libmpv. It reports false when the lookup or the sanity check fails, and
// the caller falls back to main's first statement.
func processStart() (time.Time, bool) {
	processStartFunc.once.Do(func() {
		lib, err := purego.Dlopen("/usr/lib/libproc.dylib", purego.RTLD_LAZY)
		if err != nil {
			return
		}
		fn, err := purego.Dlsym(lib, "proc_pid_rusage")
		if err != nil {
			return
		}
		processStartFunc.fn = fn
	})
	if processStartFunc.fn == 0 {
		return time.Time{}, false
	}

	// struct rusage_info_v2: 16-byte UUID, eight uint64 counters, then
	// ri_proc_start_abstime at byte 80 (sys/resource.h).
	var info [128]byte
	rc, _, _ := purego.SyscallN(processStartFunc.fn, uintptr(os.Getpid()), 2, uintptr(unsafe.Pointer(&info[0])))
	if int32(rc) != 0 {
		return time.Time{}, false
	}
	started := binary.LittleEndian.Uint64(info[80:88])

	libSystem, err := purego.Dlopen("/usr/lib/libSystem.B.dylib", purego.RTLD_LAZY)
	if err != nil {
		return time.Time{}, false
	}
	nowFn, err := purego.Dlsym(libSystem, "mach_absolute_time")
	if err != nil {
		return time.Time{}, false
	}
	timebaseFn, err := purego.Dlsym(libSystem, "mach_timebase_info")
	if err != nil {
		return time.Time{}, false
	}
	now, _, _ := purego.SyscallN(nowFn)
	var timebase struct{ Numer, Denom uint32 }
	purego.SyscallN(timebaseFn, uintptr(unsafe.Pointer(&timebase)))
	if timebase.Denom == 0 || uint64(now) <= started {
		return time.Time{}, false
	}
	age := time.Duration((uint64(now) - started) * uint64(timebase.Numer) / uint64(timebase.Denom))
	// A process older than an hour was not started by this run; trust
	// main instead of reporting nonsense.
	if age < 0 || age > time.Hour {
		return time.Time{}, false
	}
	return time.Now().Add(-age), true
}
