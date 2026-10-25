//go:build darwin

package mainq

import (
	"sync"
	"testing"

	"github.com/ebitengine/purego/objc"
)

func TestSetDispatchOverride(t *testing.T) {
	var mu sync.Mutex
	var ran []int
	SetDispatch(func(f func()) {
		mu.Lock()
		ran = append(ran, 1)
		mu.Unlock()
		f()
	})
	t.Cleanup(func() { SetDispatch(nil) })

	executed := false
	Post(func() { executed = true })
	if !executed {
		t.Fatal("Post did not run the function through the installed dispatcher")
	}
	mu.Lock()
	defer mu.Unlock()
	if len(ran) != 1 {
		t.Fatalf("dispatcher called %d times, want 1", len(ran))
	}
}

func TestPostNil(t *testing.T) {
	SetDispatch(func(f func()) {
		t.Error("dispatcher must not be called for a nil function")
	})
	t.Cleanup(func() { SetDispatch(nil) })
	Post(nil)
}

func TestSelIsCached(t *testing.T) {
	first := sel("mainqTestSelector:")
	second := sel("mainqTestSelector:")
	if first == 0 {
		t.Fatal("sel returned 0")
	}
	if first != second {
		t.Fatal("sel returned different selectors for the same name")
	}
	if want := objc.RegisterName("mainqTestSelector:"); first != want {
		t.Fatalf("sel returned %#x, objc.RegisterName returned %#x", uint64(first), uint64(want))
	}
}
