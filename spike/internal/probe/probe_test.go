package probe

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// encodeWAV builds a canonical RIFF/WAVE file with an integer PCM payload.
// testBits must be 16, 24 or 32.
func encodeWAV(t *testing.T, bits, rate, channels int, samples []float64) []byte {
	t.Helper()
	blockAlign := channels * bits / 8

	var data bytes.Buffer
	for _, v := range samples {
		switch bits {
		case 16:
			q := int32(math.Round(v * (1 << 15)))
			q = min(max(q, -1<<15), 1<<15-1)
			var b [2]byte
			binary.LittleEndian.PutUint16(b[:], uint16(int16(q)))
			data.Write(b[:])
		case 24:
			q := int64(math.Round(v * (1 << 23)))
			q = min(max(q, -1<<23), 1<<23-1)
			u := uint32(q) & 0xffffff
			data.Write([]byte{byte(u), byte(u >> 8), byte(u >> 16)})
		case 32:
			q := int64(math.Round(v * (1 << 31)))
			q = min(max(q, -1<<31), 1<<31-1)
			var b [4]byte
			binary.LittleEndian.PutUint32(b[:], uint32(int32(q)))
			data.Write(b[:])
		default:
			t.Fatalf("encodeWAV: unsupported width %d", bits)
		}
	}

	fmtChunk := make([]byte, 16)
	binary.LittleEndian.PutUint16(fmtChunk[0:], wavFormatPCM)
	binary.LittleEndian.PutUint16(fmtChunk[2:], uint16(channels))
	binary.LittleEndian.PutUint32(fmtChunk[4:], uint32(rate))
	binary.LittleEndian.PutUint32(fmtChunk[8:], uint32(rate*blockAlign))
	binary.LittleEndian.PutUint16(fmtChunk[12:], uint16(blockAlign))
	binary.LittleEndian.PutUint16(fmtChunk[14:], uint16(bits))

	riffSize := 4 + (8 + len(fmtChunk)) + (8 + data.Len())
	if data.Len()%2 == 1 {
		riffSize++ // pad byte
	}

	var out bytes.Buffer
	out.WriteString("RIFF")
	binary.Write(&out, binary.LittleEndian, uint32(riffSize))
	out.WriteString("WAVE")
	out.WriteString("fmt ")
	binary.Write(&out, binary.LittleEndian, uint32(len(fmtChunk)))
	out.Write(fmtChunk)
	out.WriteString("data")
	binary.Write(&out, binary.LittleEndian, uint32(data.Len()))
	out.Write(data.Bytes())
	if data.Len()%2 == 1 {
		out.WriteByte(0)
	}
	return out.Bytes()
}

// tone synthesizes a sine starting at phase zero.
func tone(rate int, freq, amplitude float64, d time.Duration) []float64 {
	n := int(math.Round(d.Seconds() * float64(rate)))
	out := make([]float64, n)
	for i := range n {
		out[i] = amplitude * math.Sin(2*math.Pi*freq*float64(i)/float64(rate))
	}
	return out
}

// silence synthesizes digital zeros of the requested length.
func silence(rate int, d time.Duration) []float64 {
	return make([]float64, int(math.Round(d.Seconds()*float64(rate))))
}

// interleave duplicates a mono track across channels.
func interleave(mono []float64, channels int) []float64 {
	out := make([]float64, len(mono)*channels)
	for i, v := range mono {
		for c := range channels {
			out[i*channels+c] = v
		}
	}
	return out
}

func writeTempWAV(t *testing.T, name string, raw []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	return path
}

func mustReadWAV(t *testing.T, path string) *WAV {
	t.Helper()
	w, err := ReadWAV(path)
	if err != nil {
		t.Fatalf("ReadWAV(%s): %v", path, err)
	}
	return w
}

func requireDuration(t *testing.T, what string, got, want, tolerance time.Duration) {
	t.Helper()
	if delta := got - want; delta > tolerance || delta < -tolerance {
		t.Fatalf("%s = %v, want %v ± %v (off by %v)", what, got, want, tolerance, delta)
	}
}

func requireDB(t *testing.T, what string, got, want, tolerance float64) {
	t.Helper()
	if math.Abs(got-want) > tolerance {
		t.Fatalf("%s = %.3f dBFS, want %.3f ± %.3f", what, got, want, tolerance)
	}
}

// TestWAV24Stereo is the gapless scenario: 24-bit stereo tone / gap / tone.
func TestWAV24Stereo(t *testing.T) {
	const rate = 48000
	const gap = 500 * time.Millisecond
	mono := slices.Concat(
		tone(rate, 1000, 0.5, 200*time.Millisecond),
		silence(rate, gap),
		tone(rate, 1000, 0.5, 200*time.Millisecond),
	)
	path := writeTempWAV(t, "s24le-stereo.wav", encodeWAV(t, 24, rate, 2, interleave(mono, 2)))

	w := mustReadWAV(t, path)
	if w.SampleRate != rate || w.Channels != 2 || w.Bits != 24 {
		t.Fatalf("header = %d Hz / %d ch / %d bit, want 48000 / 2 / 24", w.SampleRate, w.Channels, w.Bits)
	}
	if len(w.Samples) != len(mono)*2 {
		t.Fatalf("decoded %d samples, want %d", len(w.Samples), len(mono)*2)
	}
	requireDuration(t, "Duration", w.Duration(), 900*time.Millisecond, time.Millisecond)

	silences := w.Silences(-60, 20*time.Millisecond)
	if len(silences) != 1 {
		t.Fatalf("Silences = %+v, want exactly 1 gap", silences)
	}
	requireDuration(t, "gap start", silences[0].Start, 200*time.Millisecond, 5*time.Millisecond)
	requireDuration(t, "gap end", silences[0].End, 700*time.Millisecond, 5*time.Millisecond)
	if got := silences[0].End - silences[0].Start; got < gap-5*time.Millisecond || got > gap+5*time.Millisecond {
		t.Fatalf("gap length = %v, want %v ± 5ms", got, gap)
	}

	// A half-scale sine peaks at 20*log10(0.5) = -6.02 dBFS.
	requireDB(t, "PeakDBFS", w.PeakDBFS(), 20*math.Log10(0.5), 0.1)

	toneSNR, offToneSNR := w.ToneSNR(1000), w.ToneSNR(4500)
	t.Logf("ToneSNR(1000 Hz) = %.2f dB, ToneSNR(4500 Hz) = %.2f dB, RMS = %.2f dBFS",
		toneSNR, offToneSNR, w.RMSDBFS())
	if !(toneSNR > -6) {
		t.Fatalf("ToneSNR(1000) = %.2f dB, want the 1 kHz tone to dominate", toneSNR)
	}
	if !(toneSNR > offToneSNR+20) {
		t.Fatalf("ToneSNR(1000) = %.2f dB is not 20 dB above ToneSNR(4500) = %.2f dB", toneSNR, offToneSNR)
	}
	if got := w.ToneSNR(2 * float64(w.SampleRate)); !math.IsInf(got, -1) {
		t.Fatalf("ToneSNR above Nyquist = %v, want -Inf", got)
	}
}

// TestWAV16 covers the 16-bit mono decode path.
func TestWAV16(t *testing.T) {
	const rate = 48000
	mono := slices.Concat(
		tone(rate, 500, 0.25, 250*time.Millisecond),
		silence(rate, 250*time.Millisecond),
		tone(rate, 500, 0.25, 250*time.Millisecond),
	)
	w := mustReadWAV(t, writeTempWAV(t, "s16le-mono.wav", encodeWAV(t, 16, rate, 1, mono)))

	if w.Channels != 1 || w.Bits != 16 {
		t.Fatalf("header = %d ch / %d bit, want 1 / 16", w.Channels, w.Bits)
	}
	silences := w.Silences(-60, 20*time.Millisecond)
	if len(silences) != 1 {
		t.Fatalf("Silences = %+v, want exactly 1 gap", silences)
	}
	if got := silences[0].End - silences[0].Start; got < 245*time.Millisecond || got > 255*time.Millisecond {
		t.Fatalf("gap length = %v, want 250ms ± 5ms", got)
	}
	requireDB(t, "PeakDBFS", w.PeakDBFS(), 20*math.Log10(0.25), 0.1)
}

// TestWAV32 covers the 32-bit decode path.
func TestWAV32(t *testing.T) {
	const rate = 44100
	mono := slices.Concat(
		tone(rate, 440, 0.1, 100*time.Millisecond),
		silence(rate, 100*time.Millisecond),
	)
	w := mustReadWAV(t, writeTempWAV(t, "s32le-mono.wav", encodeWAV(t, 32, rate, 1, mono)))

	if w.Bits != 32 || w.SampleRate != rate {
		t.Fatalf("header = %d Hz / %d bit, want %d / 32", w.SampleRate, w.Bits, rate)
	}
	silences := w.Silences(-80, 20*time.Millisecond)
	if len(silences) != 1 {
		t.Fatalf("Silences = %+v, want exactly 1 gap", silences)
	}
	if got := silences[0].End - silences[0].Start; got < 95*time.Millisecond || got > 105*time.Millisecond {
		t.Fatalf("gap length = %v, want 100ms ± 5ms", got)
	}
	requireDB(t, "PeakDBFS", w.PeakDBFS(), 20*math.Log10(0.1), 0.1)
}

// TestReadFFmpegWAV wraps a known sine in each PCM flavour with ffmpeg and
// checks the decoder against the values that went in. The raw f32le source
// keeps the amplitude exact: the lavfi sine source's own level is an
// implementation detail of the installed ffmpeg.
func TestReadFFmpegWAV(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skipf("ffmpeg not on PATH: %v", err)
	}

	const rate = 48000
	mono := tone(rate, 1000, 0.5, time.Second)
	raw := make([]byte, 4*len(mono))
	for i, v := range mono {
		binary.LittleEndian.PutUint32(raw[i*4:], math.Float32bits(float32(v)))
	}
	rawPath := filepath.Join(t.TempDir(), "tone.f32le")
	if err := os.WriteFile(rawPath, raw, 0o644); err != nil {
		t.Fatalf("write %s: %v", rawPath, err)
	}

	for _, tc := range []struct {
		codec string
		bits  int
	}{
		{"pcm_s16le", 16},
		{"pcm_s24le", 24},
		{"pcm_s32le", 32},
	} {
		t.Run(tc.codec, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), tc.codec+".wav")
			cmd := exec.Command(ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error",
				"-f", "f32le", "-ar", "48000", "-ac", "1", "-i", rawPath,
				"-c:a", tc.codec, "-y", path)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("ffmpeg %s: %v: %s", tc.codec, err, out)
			}

			w := mustReadWAV(t, path)
			if w.SampleRate != rate || w.Channels != 1 || w.Bits != tc.bits {
				t.Fatalf("header = %d Hz / %d ch / %d bit, want %d / 1 / %d",
					w.SampleRate, w.Channels, w.Bits, rate, tc.bits)
			}
			if len(w.Samples) != len(mono) {
				t.Fatalf("decoded %d samples, want %d", len(w.Samples), len(mono))
			}
			requireDuration(t, "Duration", w.Duration(), time.Second, time.Millisecond)
			requireDB(t, "PeakDBFS", w.PeakDBFS(), 20*math.Log10(0.5), 0.1)
			requireDB(t, "RMSDBFS", w.RMSDBFS(), 20*math.Log10(0.5/math.Sqrt2), 0.1)
			requireDB(t, "ToneSNR(1000 Hz)", w.ToneSNR(1000), 0, 0.5)
			if silences := w.Silences(-50, 20*time.Millisecond); len(silences) != 0 {
				t.Fatalf("Silences = %+v, want none in a continuous tone", silences)
			}
			t.Logf("%d-bit: Peak %.3f dBFS, RMS %.3f dBFS, ToneSNR %.3f dB",
				tc.bits, w.PeakDBFS(), w.RMSDBFS(), w.ToneSNR(1000))
		})
	}
}

func TestSampleSelf(t *testing.T) {
	s, err := SampleSelf()
	if err != nil {
		t.Fatalf("SampleSelf: %v", err)
	}
	if s.RSSMB <= 0 {
		t.Fatalf("RSSMB = %v, want > 0", s.RSSMB)
	}
	if s.CPUPercent < 0 {
		t.Fatalf("CPUPercent = %v, want >= 0", s.CPUPercent)
	}
	if d := time.Since(s.At); d < 0 || d > time.Minute {
		t.Fatalf("sample timestamp is %v old", d)
	}
	t.Logf("pid %d: RSS %.1f MB, CPU %.2f%%", os.Getpid(), s.RSSMB, s.CPUPercent)
}

func TestSamplerJSONL(t *testing.T) {
	var buf bytes.Buffer
	stop := make(chan struct{})
	go func() {
		time.Sleep(80 * time.Millisecond)
		close(stop)
	}()
	Sampler(10*time.Millisecond, &buf, stop)

	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) < 2 {
		t.Fatalf("Sampler wrote %d lines, want at least 2:\n%s", len(lines), buf.String())
	}
	for i, line := range lines {
		var s Sample
		if err := json.Unmarshal([]byte(line), &s); err != nil {
			t.Fatalf("line %d (%q) is not JSON: %v", i, line, err)
		}
		if s.RSSMB <= 0 {
			t.Fatalf("line %d: RSSMB = %v", i, s.RSSMB)
		}
	}
	t.Logf("%d samples, first: %s", len(lines), lines[0])
}

// TestRecordMicUnattended never opens the microphone: a real capture would
// raise a TCC permission prompt. It checks that the binary we shell out to
// exists and runs, and that argument validation fails before any device is
// touched.
func TestRecordMicUnattended(t *testing.T) {
	if _, err := os.Stat(micFFmpegPath); err != nil {
		t.Skipf("ffmpeg not installed at %s: %v", micFFmpegPath, err)
	}
	out, err := exec.Command(micFFmpegPath, "-hide_banner", "-version").CombinedOutput()
	if err != nil {
		t.Fatalf("%s -version: %v: %s", micFFmpegPath, err, strings.TrimSpace(string(out)))
	}
	firstLine, _, _ := strings.Cut(strings.TrimSpace(string(out)), "\n")
	t.Logf("loopback recorder: %s", firstLine)

	if err := RecordMic(0, 48000, filepath.Join(t.TempDir(), "out.wav")); err == nil {
		t.Fatal("RecordMic(0, ...) = nil, want a validation error")
	}
	if err := RecordMic(1, 48000, ""); err == nil {
		t.Fatal(`RecordMic(1, 48000, "") = nil, want a validation error`)
	}
}
