package mpv

// The C structs below are only safe while their Go mirrors have exactly the
// C layout. These two-sided array assertions are compile-time checks: a size
// or offset that is too small or too large makes the array length negative,
// which fails the build instead of silently corrupting events at runtime.
// (The spike lost half an hour to a misread event id; the layout is the next
// easiest thing to break.)

import "unsafe"

var (
	// mpv_event: int32, int32, uint64, void* = 24 bytes; Data at 16.
	_ [unsafe.Sizeof(cEvent{}) - 24]byte
	_ [24 - unsafe.Sizeof(cEvent{})]byte
	_ [unsafe.Offsetof(cEvent{}.Data) - 16]byte
	_ [16 - unsafe.Offsetof(cEvent{}.Data)]byte

	// mpv_event_property: name, format (+padding), data = 24; Format at 8.
	_ [unsafe.Sizeof(cEventProperty{}) - 24]byte
	_ [24 - unsafe.Sizeof(cEventProperty{})]byte
	_ [unsafe.Offsetof(cEventProperty{}.Format) - 8]byte
	_ [8 - unsafe.Offsetof(cEventProperty{}.Format)]byte
	_ [unsafe.Offsetof(cEventProperty{}.Data) - 16]byte
	_ [16 - unsafe.Offsetof(cEventProperty{}.Data)]byte

	// mpv_event_end_file (0.36): reason, error, two int64 ids, int32 count.
	_ [unsafe.Sizeof(cEventEndFile{}) - 32]byte
	_ [32 - unsafe.Sizeof(cEventEndFile{})]byte
	_ [unsafe.Offsetof(cEventEndFile{}.PlaylistEntryID) - 8]byte
	_ [8 - unsafe.Offsetof(cEventEndFile{}.PlaylistEntryID)]byte
	_ [unsafe.Offsetof(cEventEndFile{}.PlaylistInsertID) - 16]byte
	_ [16 - unsafe.Offsetof(cEventEndFile{}.PlaylistInsertID)]byte
	_ [unsafe.Offsetof(cEventEndFile{}.PlaylistInsertNumEntries) - 24]byte
	_ [24 - unsafe.Offsetof(cEventEndFile{}.PlaylistInsertNumEntries)]byte

	// mpv_event_hook: name, uint64 id = 16.
	_ [unsafe.Sizeof(cEventHook{}) - 16]byte
	_ [16 - unsafe.Sizeof(cEventHook{})]byte
	_ [unsafe.Offsetof(cEventHook{}.ID) - 8]byte
	_ [8 - unsafe.Offsetof(cEventHook{}.ID)]byte

	// mpv_event_log_message: three pointers, int32 level = 32.
	_ [unsafe.Sizeof(cEventLogMessage{}) - 32]byte
	_ [32 - unsafe.Sizeof(cEventLogMessage{})]byte
	_ [unsafe.Offsetof(cEventLogMessage{}.Level) - 8]byte
	_ [8 - unsafe.Offsetof(cEventLogMessage{}.Level)]byte
	_ [unsafe.Offsetof(cEventLogMessage{}.Text) - 16]byte
	_ [16 - unsafe.Offsetof(cEventLogMessage{}.Text)]byte
	_ [unsafe.Offsetof(cEventLogMessage{}.LogLevel) - 24]byte
	_ [24 - unsafe.Offsetof(cEventLogMessage{}.LogLevel)]byte
)
