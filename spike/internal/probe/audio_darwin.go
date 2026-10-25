//go:build darwin

package probe

import (
	"errors"
	"fmt"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
)

// Paths and selectors below are transcribed from the macOS SDK headers
// (CoreAudio.framework/Headers/AudioHardware.h and
// AudioHardwareBase.h). Four-char selectors are spelled as constant
// expressions so a typo is a compile error rather than a silent 'who?'
// (kAudioHardwareUnknownPropertyError).
const (
	coreAudioFrameworkPath      = "/System/Library/Frameworks/CoreAudio.framework/CoreAudio"
	coreFoundationFrameworkPath = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"

	// kAudioObjectSystemObject: the HAL's root object.
	kAudioObjectSystemObject uint32 = 1

	// kAudioHardwarePropertyDefaultOutputDevice = 'dOut'. Note the capital
	// 'O': the selector is d-O-u-t, not 'dout'.
	selectorDefaultOutputDevice uint32 = 'd'<<24 | 'O'<<16 | 'u'<<8 | 't'
	// kAudioObjectPropertyName = 'lnam' (CFStringRef, caller releases).
	selectorObjectName uint32 = 'l'<<24 | 'n'<<16 | 'a'<<8 | 'm'
	// kAudioDevicePropertyDeviceIsRunning = 'goin' (UInt32).
	selectorDeviceIsRunning uint32 = 'g'<<24 | 'o'<<16 | 'i'<<8 | 'n'
	// kAudioDevicePropertyDeviceIsRunningSomewhere = 'gone' (UInt32).
	selectorDeviceIsRunningSomewhere uint32 = 'g'<<24 | 'o'<<16 | 'n'<<8 | 'e'

	// kAudioObjectPropertyScopeGlobal = 'glob'.
	scopeGlobal uint32 = 'g'<<24 | 'l'<<16 | 'o'<<8 | 'b'
	// kAudioObjectPropertyElementMain = 0.
	elementMain uint32 = 0

	// kAudioHardwareNoError.
	osStatusOK int32 = 0

	// kCFStringEncodingUTF8.
	cfStringEncodingUTF8 uint32 = 0x08000100
)

// audioObjectPropertyAddress mirrors the C struct of the same name: three
// consecutive UInt32 fields, 12 bytes, no padding.
type audioObjectPropertyAddress struct {
	Selector uint32
	Scope    uint32
	Element  uint32
}

// OutputStatus is a snapshot of the system's default output device.
type OutputStatus struct {
	DeviceID uint32
	Name     string
	// Running is kAudioDevicePropertyDeviceIsRunning ('goin'), i.e. the
	// device's IO proc is running in *this* process.
	Running bool
	// RunningSomewhere is kAudioDevicePropertyDeviceIsRunningSomewhere
	// ('gone'), i.e. any process is driving the device. This is the signal
	// that proves playback is actually reaching hardware.
	RunningSomewhere bool
}

// coreAudioFuncs holds the dynamically loaded HAL entry points.
type coreAudioFuncs struct {
	getPropertyDataSize func(objectID uint32, address *audioObjectPropertyAddress, qualifierSize uint32, qualifierData unsafe.Pointer, outSize *uint32) int32
	getPropertyData     func(objectID uint32, address *audioObjectPropertyAddress, qualifierSize uint32, qualifierData unsafe.Pointer, ioSize *uint32, outData unsafe.Pointer) int32
	cfStringGetCString  func(theString unsafe.Pointer, buffer *byte, bufferSize int64, encoding uint32) uint8
	cfRelease           func(cf unsafe.Pointer)
}

var (
	coreAudioOnce sync.Once
	coreAudio     *coreAudioFuncs
	coreAudioErr  error
)

// loadCoreAudio dlopens the two frameworks once per process. Callers get a
// shared, immutable function table.
func loadCoreAudio() (*coreAudioFuncs, error) {
	coreAudioOnce.Do(func() {
		coreAudio, coreAudioErr = openCoreAudio()
	})
	if coreAudioErr != nil {
		return nil, coreAudioErr
	}
	return coreAudio, nil
}

func openCoreAudio() (*coreAudioFuncs, error) {
	hal, err := purego.Dlopen(coreAudioFrameworkPath, purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		return nil, fmt.Errorf("probe: dlopen CoreAudio: %w", err)
	}
	cf, err := purego.Dlopen(coreFoundationFrameworkPath, purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		return nil, fmt.Errorf("probe: dlopen CoreFoundation: %w", err)
	}

	// A symbol that cannot be resolved means this build of macOS moved an
	// API; fail loudly instead of returning zeroed measurements.
	register := func(handle uintptr, name string, fptr any) error {
		sym, err := purego.Dlsym(handle, name)
		if err != nil {
			return fmt.Errorf("probe: dlsym %s: %w", name, err)
		}
		purego.RegisterFunc(fptr, sym)
		return nil
	}

	f := &coreAudioFuncs{}
	if err := register(hal, "AudioObjectGetPropertyDataSize", &f.getPropertyDataSize); err != nil {
		return nil, err
	}
	if err := register(hal, "AudioObjectGetPropertyData", &f.getPropertyData); err != nil {
		return nil, err
	}
	if err := register(cf, "CFStringGetCString", &f.cfStringGetCString); err != nil {
		return nil, err
	}
	if err := register(cf, "CFRelease", &f.cfRelease); err != nil {
		return nil, err
	}
	return f, nil
}

// fourCC renders an OSStatus or selector as its four-character code so
// failures read like '!obj' instead of 4294967250.
func fourCC(v uint32) string {
	b := [4]byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)}
	for i, c := range b {
		if c < 0x20 || c > 0x7e {
			b[i] = '?'
		}
	}
	return "'" + string(b[:]) + "'"
}

func (f *coreAudioFuncs) statusErr(op string, status int32) error {
	return fmt.Errorf("probe: %s: OSStatus %d (%s)", op, status, fourCC(uint32(status)))
}

// deviceUInt32 reads a UInt32 property (scope global, element main).
func (f *coreAudioFuncs) deviceUInt32(objectID uint32, selector uint32, name string) (uint32, error) {
	address := audioObjectPropertyAddress{Selector: selector, Scope: scopeGlobal, Element: elementMain}
	var value uint32
	size := uint32(unsafe.Sizeof(value))
	if status := f.getPropertyData(objectID, &address, 0, nil, &size, unsafe.Pointer(&value)); status != osStatusOK {
		return 0, f.statusErr("AudioObjectGetPropertyData("+name+")", status)
	}
	if size != uint32(unsafe.Sizeof(value)) {
		return 0, fmt.Errorf("probe: AudioObjectGetPropertyData(%s): got %d bytes, want 4", name, size)
	}
	return value, nil
}

// deviceName reads kAudioObjectPropertyName as a CFString and copies it out
// as UTF-8. The HAL returns a +1 retained CFString, which we release.
func (f *coreAudioFuncs) deviceName(objectID uint32) (string, error) {
	address := audioObjectPropertyAddress{Selector: selectorObjectName, Scope: scopeGlobal, Element: elementMain}

	// Size first: a CFString-valued property yields sizeof(CFStringRef). If
	// macOS ever reports something else, reading a pointer would corrupt
	// memory, so refuse instead.
	size := uint32(0)
	if status := f.getPropertyDataSize(objectID, &address, 0, nil, &size); status != osStatusOK {
		return "", f.statusErr("AudioObjectGetPropertyDataSize('lnam')", status)
	}
	if want := uint32(unsafe.Sizeof(uintptr(0))); size != want {
		return "", fmt.Errorf("probe: kAudioObjectPropertyName is %d bytes, want a %d-byte CFStringRef", size, want)
	}

	var cfString unsafe.Pointer
	if status := f.getPropertyData(objectID, &address, 0, nil, &size, unsafe.Pointer(&cfString)); status != osStatusOK {
		return "", f.statusErr("AudioObjectGetPropertyData('lnam')", status)
	}
	if cfString == nil {
		return "", errors.New("probe: AudioObjectGetPropertyData('lnam') returned a null CFString")
	}
	defer f.cfRelease(cfString)

	var buf [512]byte
	if f.cfStringGetCString(cfString, &buf[0], int64(len(buf)), cfStringEncodingUTF8) == 0 {
		return "", errors.New("probe: CFStringGetCString failed (name longer than 512 bytes?)")
	}
	for i, c := range buf {
		if c == 0 {
			return string(buf[:i]), nil
		}
	}
	// No NUL terminator: the conversion above promised one, so treat the
	// full buffer as the name rather than silently truncating.
	return string(buf[:]), nil
}

// DefaultOutput reports the current default output device and whether it is
// running. It returns an error if the HAL has no default output device or
// the device's name cannot be read.
func DefaultOutput() (OutputStatus, error) {
	f, err := loadCoreAudio()
	if err != nil {
		return OutputStatus{}, err
	}

	deviceID, err := f.deviceUInt32(kAudioObjectSystemObject, selectorDefaultOutputDevice, "default output device")
	if err != nil {
		return OutputStatus{}, err
	}
	if deviceID == 0 {
		return OutputStatus{}, errors.New("probe: no default output device (kAudioObjectUnknown)")
	}

	name, err := f.deviceName(deviceID)
	if err != nil {
		return OutputStatus{}, err
	}

	running, err := f.deviceUInt32(deviceID, selectorDeviceIsRunning, "'goin'")
	if err != nil {
		return OutputStatus{}, err
	}
	runningSomewhere, err := f.deviceUInt32(deviceID, selectorDeviceIsRunningSomewhere, "'gone'")
	if err != nil {
		return OutputStatus{}, err
	}

	return OutputStatus{
		DeviceID:         deviceID,
		Name:             name,
		Running:          running != 0,
		RunningSomewhere: runningSomewhere != 0,
	}, nil
}
