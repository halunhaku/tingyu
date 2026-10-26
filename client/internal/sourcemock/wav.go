// Package sourcemock serves the two remote protocols M3 implements, locally
// and faithfully enough to test the production clients: a WebDAV server that
// speaks PROPFIND/Depth/Basic/Range, and a Quark Drive server that speaks the
// endpoint shapes, status codes, cookie flow and direct-link expiry the Flutter
// client's parsers expect.
//
// It is a development/acceptance tool, not part of the app (like rangesrv for
// M2): nothing under internal/app imports it. The shapes are copied from the
// Dart parsers, not from official Quark documentation — there is none — and
// the M3 record says which parts therefore remain unverified against the real
// service.
package sourcemock

import (
	"encoding/binary"
	"math"
)

// WAV builds a mono 16-bit PCM sine sweep long enough to seek in. It is a real
// playable file, so playback through libmpv exercises the same path a remote
// track does.
func WAV(seconds float64, sampleRate int) []byte {
	if sampleRate <= 0 {
		sampleRate = 48000
	}
	if seconds <= 0 {
		seconds = 1
	}
	samples := int(seconds * float64(sampleRate))
	dataSize := samples * 2
	buffer := make([]byte, 44+dataSize)
	copy(buffer[0:4], "RIFF")
	binary.LittleEndian.PutUint32(buffer[4:8], uint32(36+dataSize))
	copy(buffer[8:12], "WAVE")
	copy(buffer[12:16], "fmt ")
	binary.LittleEndian.PutUint32(buffer[16:20], 16)
	binary.LittleEndian.PutUint16(buffer[20:22], 1) // PCM
	binary.LittleEndian.PutUint16(buffer[22:24], 1) // mono
	binary.LittleEndian.PutUint32(buffer[24:28], uint32(sampleRate))
	binary.LittleEndian.PutUint32(buffer[28:32], uint32(sampleRate*2))
	binary.LittleEndian.PutUint16(buffer[32:34], 2)
	binary.LittleEndian.PutUint16(buffer[34:36], 16)
	copy(buffer[36:40], "data")
	binary.LittleEndian.PutUint32(buffer[40:44], uint32(dataSize))
	frequency := 440.0
	for i := 0; i < samples; i++ {
		value := math.Sin(2 * math.Pi * frequency * float64(i) / float64(sampleRate))
		binary.LittleEndian.PutUint16(buffer[44+i*2:], uint16(int16(value*0.3*math.MaxInt16)))
	}
	return buffer
}
