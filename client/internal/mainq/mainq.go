//go:build darwin

// Package mainq runs work on the process's main thread.
//
// MediaPlayer's MPNowPlayingInfoCenter and MPRemoteCommandCenter are meant to
// be driven from the main thread, and the NSApplication run loop that hands
// out media keys has to live there, so mediasession routes every Objective-C
// call through this package.
//
// The package is pure Go: libobjc, libdispatch and AppKit are loaded with
// purego.Dlopen (RTLD_LAZY, so undefined symbols such as libmpv's libass
// imports are not resolved up front) and messaged through objc_msgSend.
package mainq

import (
	"errors"
	"fmt"
	"runtime"
	"sync"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
)

const (
	pathLibObjC   = "/usr/lib/libobjc.A.dylib"
	pathLibSystem = "/usr/lib/libSystem.B.dylib"
	pathAppKit    = "/System/Library/Frameworks/AppKit.framework/AppKit"

	// NSApplicationActivationPolicyAccessory keeps the process out of the Dock
	// and the ⌘-Tab switcher while still letting it become the Now Playing app.
	nsApplicationActivationPolicyAccessory = 1
)

var (
	// dispatch is the optional override installed by SetDispatch.
	dispatchMu sync.RWMutex
	dispatch   func(func())

	loadOnce sync.Once
	loadErr  error

	// Objective-C plumbing, resolved by load.
	poolPush      func() uintptr
	poolPop       func(uintptr)
	pthreadMainNP func() int32
	mainQueue     uintptr
	getMainQueue  func() uintptr
	dispatchAsync func(queue uintptr, block objc.Block)
	msgSendID     func(objc.ID, objc.SEL) objc.ID
	msgSendVoid   func(objc.ID, objc.SEL)
	msgSendInt    func(objc.ID, objc.SEL, int64)

	// pump is the single block handed to libdispatch for every wakeup; it
	// drains the Go-side queue on the main thread.
	pump objc.Block

	queueMu sync.Mutex
	queue   []func()

	selMu sync.Mutex
	sels  = map[string]objc.SEL{}
)

// sel returns the cached selector of name. objc.RegisterName takes the global
// Objective-C lock, so callers must not do it per message.
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

// load resolves libobjc, libdispatch and the message-send variants once.
func load() error {
	loadOnce.Do(func() {
		objcLib, err := purego.Dlopen(pathLibObjC, purego.RTLD_LAZY|purego.RTLD_GLOBAL)
		if err != nil {
			loadErr = fmt.Errorf("mainq: dlopen libobjc: %w", err)
			return
		}
		purego.RegisterLibFunc(&poolPush, objcLib, "objc_autoreleasePoolPush")
		purego.RegisterLibFunc(&poolPop, objcLib, "objc_autoreleasePoolPop")
		// libdispatch and pthread live in libSystem, which every process has
		// mapped; an explicit handle is used because RTLD_DEFAULT lookups of
		// these symbols are not reliable on current macOS.
		libSystem, err := purego.Dlopen(pathLibSystem, purego.RTLD_LAZY|purego.RTLD_GLOBAL)
		if err != nil {
			loadErr = fmt.Errorf("mainq: dlopen libSystem: %w", err)
			return
		}
		// dispatch_get_main_queue is no longer exported by name on macOS 26+;
		// it only returns &_dispatch_main_q, which is exported.
		if addr, err := purego.Dlsym(libSystem, "dispatch_get_main_queue"); err == nil {
			purego.RegisterFunc(&getMainQueue, addr)
			mainQueue = getMainQueue()
		} else if addr, err := purego.Dlsym(libSystem, "_dispatch_main_q"); err == nil {
			mainQueue = addr
		} else {
			loadErr = fmt.Errorf("mainq: no main queue: %w", err)
			return
		}
		purego.RegisterLibFunc(&dispatchAsync, libSystem, "dispatch_async")
		purego.RegisterLibFunc(&pthreadMainNP, libSystem, "pthread_main_np")
		msgSend, err := purego.Dlsym(objcLib, "objc_msgSend")
		if err != nil {
			loadErr = fmt.Errorf("mainq: dlsym objc_msgSend: %w", err)
			return
		}
		purego.RegisterFunc(&msgSendID, msgSend)
		purego.RegisterFunc(&msgSendVoid, msgSend)
		purego.RegisterFunc(&msgSendInt, msgSend)
		pump = objc.NewBlock(func(objc.Block) {
			// Entering Objective-C: keep this goroutine on the main thread for
			// the whole batch, so a queued update cannot resume elsewhere.
			runtime.LockOSThread()
			defer runtime.UnlockOSThread()
			pool := poolPush()
			drain()
			poolPop(pool)
		})
	})
	return loadErr
}

// SetDispatch replaces the default "dispatch_async to the main queue" with fn.
// The function must run f on the main thread; it is not called by Post when the
// caller already is on the main thread.
func SetDispatch(fn func(func())) {
	dispatchMu.Lock()
	dispatch = fn
	dispatchMu.Unlock()
}

// Post runs f on the main thread.
//
// On the main thread f runs inline, inside a fresh autorelease pool and with
// the thread locked, so callers can use it as a synchronous "apply on main"
// primitive. From any other goroutine f is appended to a queue and libdispatch
// wakes the main queue, whose block drains the whole queue. That keeps a single
// Objective-C block alive for the life of the process instead of allocating one
// per call.
//
// The dispatched path needs the main thread to be draining its queue, i.e. a
// run loop (see RunAppLoop) or any AppKit app loop. A harness without one must
// keep its main goroutine on the main thread with LockMainThread, otherwise
// nothing ever runs the queued work.
func Post(f func()) {
	if f == nil {
		return
	}
	dispatchMu.RLock()
	custom := dispatch
	dispatchMu.RUnlock()
	if custom != nil {
		custom(f)
		return
	}
	if err := load(); err != nil {
		panic(err)
	}
	if pthreadMainNP() == 1 {
		runPooled(f)
		return
	}
	queueMu.Lock()
	queue = append(queue, f)
	queueMu.Unlock()
	dispatchAsync(mainQueue, pump)
}

// runPooled runs f with the thread locked and an autorelease pool pushed, as
// required when entering Objective-C.
func runPooled(f func()) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	pool := poolPush()
	defer poolPop(pool)
	f()
}

// drain runs every queued function. Called from the main thread only.
func drain() {
	for {
		queueMu.Lock()
		batch := queue
		queue = nil
		queueMu.Unlock()
		if len(batch) == 0 {
			return
		}
		for _, f := range batch {
			f()
		}
	}
}

// RunAppLoop loads AppKit and runs the NSApplication event loop on the calling
// goroutine's thread. It never returns.
//
// Only standalone harnesses call it: a real app already has a run loop, and the
// media keys (and the Now Playing projection) need one on the main thread. Call
// it from the main goroutine.
func RunAppLoop() {
	runtime.LockOSThread()
	if err := load(); err != nil {
		panic(err)
	}
	appKit, err := purego.Dlopen(pathAppKit, purego.RTLD_LAZY|purego.RTLD_GLOBAL)
	if err != nil {
		panic(fmt.Errorf("mainq: dlopen AppKit: %w", err))
	}
	var nsApplicationLoad func() bool
	purego.RegisterLibFunc(&nsApplicationLoad, appKit, "NSApplicationLoad")
	nsApplicationLoad()

	app := msgSendID(objc.ID(objc.GetClass("NSApplication")), sel("sharedApplication"))
	if app == 0 {
		panic("mainq: no NSApplication")
	}
	msgSendInt(app, sel("setActivationPolicy:"), nsApplicationActivationPolicyAccessory)
	msgSendVoid(app, sel("run"))
	// [NSApp run] only returns when the app terminates; make that explicit.
	select {}
}

// LockMainThread pins the calling goroutine to the main thread and fails unless
// it already is the main thread. Harnesses that drive main-thread-only APIs
// without a run loop call this first: Go may otherwise migrate the main
// goroutine off the main thread, and Post would then queue work that nothing
// drains.
func LockMainThread() error {
	if err := load(); err != nil {
		return err
	}
	if pthreadMainNP() != 1 {
		return errors.New("mainq: not running on the main thread")
	}
	runtime.LockOSThread()
	return nil
}

// OnMainThread reports whether the caller is running on the process's main
// thread.
func OnMainThread() bool {
	if err := load(); err != nil {
		panic(err)
	}
	return pthreadMainNP() == 1
}
