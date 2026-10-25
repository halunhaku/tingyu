package accept

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"os"
	"time"
)

// wavData is a decoded PCM WAV file, mixed down to one channel. The gapless
// check renders the player's real audio output through mpv's pcm AO and looks
// for silence: a measurement of what the audio device would have heard, not a
// reading of mpv's state (spike §7.1 threshold 5).
type wavData struct {
	SampleRate int
	Channels   int
	Bits       int
	Samples    []float64
}

// Duration is the rendered length.
func (w *wavData) Duration() time.Duration {
	if w.SampleRate == 0 {
		return 0
	}
	return time.Duration(float64(len(w.Samples)) / float64(w.SampleRate) * float64(time.Second))
}

// readWAV parses a RIFF/WAVE file written by mpv's pcm AO, which uses
// WAVE_FORMAT_EXTENSIBLE with a float subtype.
func readWAV(path string) (*wavData, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(raw) < 12 || string(raw[0:4]) != "RIFF" || string(raw[8:12]) != "WAVE" {
		return nil, errors.New("not a RIFF/WAVE file")
	}
	var (
		formatTag  uint16
		channels   uint16
		sampleRate uint32
		bits       uint16
		data       []byte
	)
	for offset := 12; offset+8 <= len(raw); {
		id := string(raw[offset : offset+4])
		size := int(binary.LittleEndian.Uint32(raw[offset+4 : offset+8]))
		body := raw[offset+8:]
		if size > len(body) {
			size = len(body)
		}
		switch id {
		case "fmt ":
			if size < 16 {
				return nil, errors.New("short fmt chunk")
			}
			formatTag = binary.LittleEndian.Uint16(body[0:2])
			channels = binary.LittleEndian.Uint16(body[2:4])
			sampleRate = binary.LittleEndian.Uint32(body[4:8])
			bits = binary.LittleEndian.Uint16(body[14:16])
			if formatTag == 0xFFFE && size >= 26 { // WAVE_FORMAT_EXTENSIBLE
				formatTag = binary.LittleEndian.Uint16(body[24:26])
			}
		case "data":
			data = body[:size]
		}
		offset += 8 + size + size%2 // chunks are word-aligned
	}
	if channels == 0 || sampleRate == 0 || len(data) == 0 {
		return nil, fmt.Errorf("incomplete WAV: channels=%d rate=%d data=%d", channels, sampleRate, len(data))
	}
	samples, err := decodePCM(data, int(bits), int(channels))
	if err != nil {
		return nil, err
	}
	return &wavData{SampleRate: int(sampleRate), Channels: int(channels), Bits: int(bits), Samples: samples}, nil
}

// decodePCM converts interleaved samples to a mono float signal in [-1, 1].
func decodePCM(data []byte, bits, channels int) ([]float64, error) {
	frames := len(data) / (bits / 8) / channels
	out := make([]float64, 0, frames)
	for frame := range frames {
		var sum float64
		for channel := range channels {
			offset := (frame*channels + channel) * bits / 8
			value, err := sampleAt(data, offset, bits)
			if err != nil {
				return nil, err
			}
			sum += value
		}
		out = append(out, sum/float64(channels))
	}
	return out, nil
}

func sampleAt(data []byte, offset, bits int) (float64, error) {
	switch bits {
	case 16:
		return float64(int16(binary.LittleEndian.Uint16(data[offset:]))) / 32768, nil
	case 24:
		raw := int32(data[offset]) | int32(data[offset+1])<<8 | int32(data[offset+2])<<16
		if raw&0x800000 != 0 {
			raw |= ^0xFFFFFF
		}
		return float64(raw) / 8388608, nil
	case 32:
		// mpv's pcm AO writes floats when the format is float; a 32-bit int
		// file would be misread, so callers ask for float explicitly.
		value := math.Float32frombits(binary.LittleEndian.Uint32(data[offset:]))
		return float64(value), nil
	}
	return 0, fmt.Errorf("unsupported sample width %d", bits)
}

// silenceRun is one contiguous stretch quieter than the threshold.
type silenceRun struct {
	Start time.Duration
	End   time.Duration
}

// silences finds stretches at or below thresholdDBFS lasting at least
// minimum. A gap between two gapless tracks would show up as one.
func (w *wavData) silences(thresholdDBFS float64, minimum time.Duration) []silenceRun {
	threshold := math.Pow(10, thresholdDBFS/20)
	minimumFrames := int(float64(w.SampleRate) * minimum.Seconds())
	var runs []silenceRun
	start := -1
	for index, sample := range w.Samples {
		quiet := math.Abs(sample) <= threshold
		if quiet && start < 0 {
			start = index
		}
		if !quiet && start >= 0 {
			if index-start >= minimumFrames {
				runs = append(runs, silenceRun{
					Start: time.Duration(float64(start) / float64(w.SampleRate) * float64(time.Second)),
					End:   time.Duration(float64(index) / float64(w.SampleRate) * float64(time.Second)),
				})
			}
			start = -1
		}
	}
	if start >= 0 && len(w.Samples)-start >= minimumFrames {
		runs = append(runs, silenceRun{
			Start: time.Duration(float64(start) / float64(w.SampleRate) * float64(time.Second)),
			End:   w.Duration(),
		})
	}
	return runs
}

// peakDBFS is the loudest sample as decibels below full scale; -Inf for
// digital silence.
func (w *wavData) peakDBFS() float64 {
	peak := 0.0
	for _, sample := range w.Samples {
		if value := math.Abs(sample); value > peak {
			peak = value
		}
	}
	if peak == 0 {
		return math.Inf(-1)
	}
	return 20 * math.Log10(peak)
}
