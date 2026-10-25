//go:build darwin

package mediasession

// Keeping the process out of App Nap and the machine out of idle sleep while
// audio plays needs two independent facilities:
//
//   - NSProcessInfo -beginActivityWithOptions:reason:, which stops App Nap from
//     throttling timers and I/O of the process, and
//   - an IOKit power assertion (kIOPMAssertionTypeNoIdleSleep), which is what
//     actually shows up in `pmset -g assertions` and prevents idle sleep.
//
// Both are created and torn down on the main thread, like the rest of the
// Objective-C state.

import (
	"errors"
	"fmt"
	"sync"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
)

const (
	// Foundation/NSProcessInfo.h:
	//   NSActivityUserInitiated = 0x00FFFFFFULL | NSActivityIdleSystemSleepDisabled
	//   NSActivityUserInitiatedAllowingIdleSystemSleep = NSActivityUserInitiated & ~NSActivityIdleSystemSleepDisabled
	// Bit 20 already sits inside the low 24 bits of 0x00FFFFFF, so
	// UserInitiated is 0x00FFFFFF and AllowingIdleSystemSleep is 0x00EFFFFF.
	// (The commonly quoted 0x00FFFFFF00000001 is not what the headers define.)
	nsActivityIdleSystemSleepDisabled              = uint64(1) << 20
	nsActivityUserInitiated                        = uint64(0x00FFFFFF) | nsActivityIdleSystemSleepDisabled
	nsActivityUserInitiatedAllowingIdleSystemSleep = nsActivityUserInitiated &^ nsActivityIdleSystemSleepDisabled

	kIOPMAssertionLevelOn = 255
	kCFStringEncodingUTF8 = 0x08000100

	// The IOPMLib.h assertion types are CFSTR(...) literals, not exported
	// symbols, so they are rebuilt here. kIOPMAssertionTypeNoIdleSleep is the
	// same assertion, deprecated since 10.7 in favour of this name; the system
	// substitutes it for the deprecated one anyway.
	assertionTypeNoIdleSleep = "PreventUserIdleSystemSleep"

	// Both names are picked up by `pmset -g assertions`.
	assertionName  = "听屿: playing audio"
	activityReason = "听屿: playing audio"
)

var (
	ioOnce sync.Once
	ioErr  error

	createAssertion  func(typ uintptr, level uint32, name uintptr, id *uint32) int32
	releaseAssertion func(id uint32) int32
	cfStringCreate   func(alloc uintptr, cstr string, enc uint32) uintptr
	cfRelease        func(cf uintptr)
	assertionType    uintptr // CFStringRef: assertionTypeNoIdleSleep

	// Main-thread only.
	activityToken objc.ID // the retained NSObject<NSProcessInfoActivity>
	assertionID   uint32
)

// SetKeepsAwake turns the App Nap activity and the idle sleep assertion on or
// off. It is idempotent, so a player can call it on every state change.
func SetKeepsAwake(on bool) error {
	if err := Init(); err != nil {
		return err
	}
	var err error
	if waitErr := applyOnMain(func() {
		if on {
			err = beginAwake()
		} else {
			endAwake()
		}
	}); waitErr != nil {
		return waitErr
	}
	return err
}

// beginAwake creates both guards. Main thread only.
func beginAwake() error {
	if activityToken != 0 && assertionID != 0 {
		return nil
	}
	if err := loadIOKit(); err != nil {
		return err
	}
	if activityToken == 0 {
		processInfo := msgID(class("NSProcessInfo"), sel("processInfo"))
		token := msgIDOptions(processInfo, sel("beginActivityWithOptions:reason:"),
			nsActivityUserInitiatedAllowingIdleSystemSleep, nsString(activityReason))
		if token == 0 {
			return errors.New("mediasession: beginActivityWithOptions:reason: returned nil")
		}
		// Hold the token ourselves; -endActivity: balances it.
		activityToken = msgID(token, sel("retain"))
	}
	if assertionID == 0 {
		name := cfStringCreate(0, assertionName, kCFStringEncodingUTF8)
		if name == 0 {
			endAwake()
			return errors.New("mediasession: CFStringCreateWithCString failed for the power assertion")
		}
		var id uint32
		result := createAssertion(assertionType, kIOPMAssertionLevelOn, name, &id)
		cfRelease(name)
		if result != 0 {
			endAwake()
			return fmt.Errorf("mediasession: IOPMAssertionCreateWithName failed (IOReturn %#x)", result)
		}
		assertionID = id
	}
	return nil
}

// endAwake releases both guards. Main thread only.
func endAwake() {
	if activityToken != 0 {
		processInfo := msgID(class("NSProcessInfo"), sel("processInfo"))
		msgVoidID(processInfo, sel("endActivity:"), activityToken)
		msgVoid(activityToken, sel("release"))
		activityToken = 0
	}
	if assertionID != 0 {
		releaseAssertion(assertionID)
		assertionID = 0
	}
}

// loadIOKit resolves IOKit and CoreFoundation once.
func loadIOKit() error {
	ioOnce.Do(func() {
		coreFoundation, err := purego.Dlopen(pathCoreFoundation, purego.RTLD_LAZY|purego.RTLD_GLOBAL)
		if err != nil {
			ioErr = fmt.Errorf("mediasession: dlopen CoreFoundation: %w", err)
			return
		}
		ioKit, err := purego.Dlopen(pathIOKit, purego.RTLD_LAZY|purego.RTLD_GLOBAL)
		if err != nil {
			ioErr = fmt.Errorf("mediasession: dlopen IOKit: %w", err)
			return
		}
		purego.RegisterLibFunc(&createAssertion, ioKit, "IOPMAssertionCreateWithName")
		purego.RegisterLibFunc(&releaseAssertion, ioKit, "IOPMAssertionRelease")
		purego.RegisterLibFunc(&cfStringCreate, coreFoundation, "CFStringCreateWithCString")
		purego.RegisterLibFunc(&cfRelease, coreFoundation, "CFRelease")
		assertionType = cfStringCreate(0, assertionTypeNoIdleSleep, kCFStringEncodingUTF8)
		if assertionType == 0 {
			ioErr = errors.New("mediasession: CFStringCreateWithCString failed for the assertion type")
			return
		}
	})
	return ioErr
}
