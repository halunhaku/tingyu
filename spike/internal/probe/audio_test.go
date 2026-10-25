//go:build darwin

package probe

import (
	"testing"
	"unsafe"
)

// TestAudioObjectPropertyAddressLayout pins the C struct layout that
// AudioObjectGetPropertyData reads through a pointer.
func TestAudioObjectPropertyAddressLayout(t *testing.T) {
	if got, want := unsafe.Sizeof(audioObjectPropertyAddress{}), uintptr(12); got != want {
		t.Fatalf("sizeof(AudioObjectPropertyAddress) = %d, want %d", got, want)
	}
}

// TestDefaultOutput talks to the real CoreAudio HAL. RunningSomewhere is only
// reported, never asserted: this Mac may not be playing anything.
func TestDefaultOutput(t *testing.T) {
	status, err := DefaultOutput()
	if err != nil {
		t.Fatalf("DefaultOutput: %v", err)
	}
	if status.DeviceID == 0 {
		t.Fatal("DeviceID = 0, want the real default output device")
	}
	if status.Name == "" {
		t.Fatal("Name is empty, want the default output device's CFString name")
	}
	if !status.Running && !status.RunningSomewhere {
		t.Logf("note: device is idle; the test does not play anything")
	}
	t.Logf("default output device: id=%d name=%q running=%v runningSomewhere=%v",
		status.DeviceID, status.Name, status.Running, status.RunningSomewhere)
}
