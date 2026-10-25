// Package probe measures what a media spike can actually observe on this Mac:
// the real CoreAudio default output device, this process's memory and CPU
// footprint, and the acoustic properties of rendered WAV files.
package probe

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"os"
	"time"
)

// RIFF/WAVE format tags we understand.
const (
	wavFormatPCM        uint16 = 1
	wavFormatExtensible uint16 = 0xfffe
)

// WAV is a decoded, single-format PCM WAV file. Samples are interleaved
// frame-major and normalized to [-1, 1].
type WAV struct {
	SampleRate int
	Channels   int
	Bits       int
	Samples    []float64
}

// Silence is a half-open span [Start, End) during which every channel stayed
// below the detection threshold.
type Silence struct {
	Start time.Duration
	End   time.Duration
}

// ReadWAV decodes an integer PCM WAV file (16, 24 or 32 bit signed samples,
// including WAVE_FORMAT_EXTENSIBLE with a PCM subformat). Floating point and
// compressed payloads are rejected rather than misread.
func ReadWAV(path string) (*WAV, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("probe: read wav %s: %w", path, err)
	}
	w, err := parseWAV(raw)
	if err != nil {
		return nil, fmt.Errorf("probe: %s: %w", path, err)
	}
	return w, nil
}

func parseWAV(raw []byte) (*WAV, error) {
	if len(raw) < 12 || string(raw[0:4]) != "RIFF" || string(raw[8:12]) != "WAVE" {
		return nil, errors.New("not a RIFF/WAVE file")
	}

	var (
		formatTag    uint16
		channels     uint16
		sampleRate   uint32
		bitsPerSampl uint16
		data         []byte
		haveFmt      bool
	)
	for off := 12; off+8 <= len(raw); {
		id := string(raw[off : off+4])
		declared := binary.LittleEndian.Uint32(raw[off+4 : off+8])
		start := off + 8
		if uint64(start)+uint64(declared) > uint64(len(raw)) {
			return nil, fmt.Errorf("truncated %q chunk: declares %d bytes, %d available", id, declared, len(raw)-start)
		}
		body := raw[start : start+int(declared)]

		switch id {
		case "fmt ":
			if len(body) < 16 {
				return nil, fmt.Errorf("fmt chunk too short: %d bytes", len(body))
			}
			formatTag = binary.LittleEndian.Uint16(body[0:2])
			channels = binary.LittleEndian.Uint16(body[2:4])
			sampleRate = binary.LittleEndian.Uint32(body[4:8])
			bitsPerSampl = binary.LittleEndian.Uint16(body[14:16])
			if formatTag == wavFormatExtensible {
				// WAVEFORMATEXTENSIBLE: cbSize(2) validBits(2) channelMask(4)
				// then a 16-byte SubFormat GUID whose first two bytes are the
				// format tag for PCM GUIDs.
				if len(body) < 26 {
					return nil, fmt.Errorf("extensible fmt chunk too short: %d bytes", len(body))
				}
				if sub := binary.LittleEndian.Uint16(body[24:26]); sub != wavFormatPCM {
					return nil, fmt.Errorf("unsupported extensible subformat %d", sub)
				}
				formatTag = wavFormatPCM
			}
			haveFmt = true
		case "data":
			data = body
		}

		off = start + int(declared)
		if declared%2 == 1 {
			off++ // chunks are word aligned
		}
	}

	if !haveFmt {
		return nil, errors.New("missing fmt chunk")
	}
	if data == nil {
		return nil, errors.New("missing data chunk")
	}
	if formatTag != wavFormatPCM {
		return nil, fmt.Errorf("unsupported WAV format tag %d (only integer PCM is decoded)", formatTag)
	}
	if channels == 0 || sampleRate == 0 {
		return nil, fmt.Errorf("invalid header: %d channels at %d Hz", channels, sampleRate)
	}
	switch bitsPerSampl {
	case 16, 24, 32:
	case 8:
		return nil, errors.New("8-bit PCM is not supported")
	default:
		return nil, fmt.Errorf("unsupported sample width %d bits", bitsPerSampl)
	}

	blockAlign := int(channels) * int(bitsPerSampl) / 8
	if len(data)%blockAlign != 0 {
		return nil, fmt.Errorf("data chunk of %d bytes is not a whole number of %d-byte frames", len(data), blockAlign)
	}

	samples, err := decodePCM(data, int(bitsPerSampl))
	if err != nil {
		return nil, err
	}
	return &WAV{
		SampleRate: int(sampleRate),
		Channels:   int(channels),
		Bits:       int(bitsPerSampl),
		Samples:    samples,
	}, nil
}

// decodePCM converts packed little-endian signed integers to floats in
// [-1, 1). Each width is normalized by its own full scale, so 24-bit silence
// and 24-bit full scale both land exactly where 16-bit would.
func decodePCM(data []byte, bits int) ([]float64, error) {
	width := bits / 8
	out := make([]float64, len(data)/width)
	for i := range out {
		p := data[i*width:]
		switch bits {
		case 16:
			out[i] = float64(int16(binary.LittleEndian.Uint16(p))) / (1 << 15)
		case 24:
			u := uint32(p[0]) | uint32(p[1])<<8 | uint32(p[2])<<16
			if u&0x800000 != 0 {
				u |= 0xff000000 // sign extend
			}
			out[i] = float64(int32(u)) / (1 << 23)
		case 32:
			out[i] = float64(int32(binary.LittleEndian.Uint32(p))) / (1 << 31)
		default:
			return nil, fmt.Errorf("unsupported sample width %d bits", bits)
		}
	}
	return out, nil
}

// frames is the number of interleaved sample frames.
func (w *WAV) frames() int {
	if w.Channels <= 0 {
		return 0
	}
	return len(w.Samples) / w.Channels
}

// frameAt returns the duration of the first frameIndex frames, rounded to the
// nearest nanosecond.
func (w *WAV) frameAt(frameIndex int64) time.Duration {
	if w.SampleRate <= 0 {
		return 0
	}
	rate := int64(w.SampleRate)
	return time.Duration((frameIndex*int64(time.Second) + rate/2) / rate)
}

// Duration is the playback length of the file.
func (w *WAV) Duration() time.Duration {
	return w.frameAt(int64(w.frames()))
}

// PeakDBFS is the largest absolute sample value in dBFS over all channels.
// A digital-silent file reports -Inf.
func (w *WAV) PeakDBFS() float64 {
	peak := 0.0
	for _, s := range w.Samples {
		if a := math.Abs(s); a > peak {
			peak = a
		}
	}
	if peak == 0 {
		return math.Inf(-1)
	}
	return 20 * math.Log10(peak)
}

// RMSDBFS is the root-mean-square level in dBFS over all channels, silence
// included. A digital-silent file reports -Inf.
func (w *WAV) RMSDBFS() float64 {
	if len(w.Samples) == 0 {
		return math.Inf(-1)
	}
	sum := 0.0
	for _, s := range w.Samples {
		sum += s * s
	}
	mean := sum / float64(len(w.Samples))
	if mean == 0 {
		return math.Inf(-1)
	}
	return 10 * math.Log10(mean)
}

// ToneSNR estimates how much of the signal's power sits at freq by running a
// Goertzel filter over the mono downmix. It returns 10*log10(tonePower /
// fullBandMeanPower): a coherent sine that accounts for all of the signal's
// power measures 0 dB, and a sine buried under noise measures negative dB.
// The result is -Inf for a digital-silent file or a frequency outside
// (0, sampleRate/2).
func (w *WAV) ToneSNR(freq float64) float64 {
	n := w.frames()
	if n == 0 || freq <= 0 || freq >= float64(w.SampleRate)/2 {
		return math.Inf(-1)
	}

	coeff := 2 * math.Cos(2*math.Pi*freq/float64(w.SampleRate))
	var s1, s2, sumSquares float64
	channels := float64(w.Channels)
	for i := range n {
		x := 0.0
		for c := range w.Channels {
			x += w.Samples[i*w.Channels+c]
		}
		x /= channels
		sumSquares += x * x
		s0 := x + coeff*s1 - s2
		s2, s1 = s1, s0
	}

	meanPower := sumSquares / float64(n)
	if meanPower == 0 {
		return math.Inf(-1)
	}
	// |X(k)|^2 from the Goertzel state, then the mean square a coherent
	// sinusoid of that bin magnitude would carry: 2*|X|^2/N^2.
	binPower := s1*s1 + s2*s2 - coeff*s1*s2
	tonePower := 2 * binPower / (float64(n) * float64(n))
	if tonePower <= 0 {
		return math.Inf(-1)
	}
	return 10 * math.Log10(tonePower/meanPower)
}

// Silences finds spans of at least minRun where every channel stays at or
// below thresholdDBFS. A frame is silent when its loudest channel is below
// the threshold, so a gap in only one channel of a stereo file does not count
// as silence. Leading and trailing silence are reported too, which is what
// gapless and gap measurements need.
func (w *WAV) Silences(thresholdDBFS float64, minRun time.Duration) []Silence {
	frames := w.frames()
	if frames == 0 || w.SampleRate <= 0 {
		return nil
	}
	amplitude := math.Pow(10, thresholdDBFS/20)
	minFrames := int64(math.Round(minRun.Seconds() * float64(w.SampleRate)))
	if minFrames < 1 {
		minFrames = 1
	}

	var out []Silence
	runStart := int64(-1)
	flush := func(end int64) {
		if runStart >= 0 && end-runStart >= minFrames {
			out = append(out, Silence{Start: w.frameAt(runStart), End: w.frameAt(end)})
		}
		runStart = -1
	}

	for i := range frames {
		silent := true
		for c := range w.Channels {
			if math.Abs(w.Samples[i*w.Channels+c]) > amplitude {
				silent = false
				break
			}
		}
		if silent {
			if runStart < 0 {
				runStart = int64(i)
			}
			continue
		}
		flush(int64(i))
	}
	flush(int64(frames))
	return out
}

// ToneSNRSearch 在 freq*(1±tol) 范围内按 FFT 频率分辨率扫描一遍 ToneSNR，
// 返回最大值与取得它的频点。
//
// 为什么需要它：Goertzel 是定频的，实录音频里的音高会有偏移
// （声学回环：播放 440 Hz，录回来实测约 437 Hz，光谱能量压在 430–450 Hz 一带），
// 定频点正好落在旁瓣之外就会读成"没有音"。扫描后仍取最大值，判别力不变。
func (w *WAV) ToneSNRSearch(freq, tol float64) (snrDB, bestFreq float64) {
	n := w.frames()
	if n == 0 || freq <= 0 {
		return math.Inf(-1), 0
	}
	binHz := float64(w.SampleRate) / float64(n)
	step := binHz / 2
	lo, hi := freq*(1-tol), freq*(1+tol)
	bestDB, bestF := math.Inf(-1), freq
	for f := lo; f <= hi; f += step {
		if f >= float64(w.SampleRate)/2 {
			break
		}
		if db := w.ToneSNR(f); db > bestDB {
			bestDB, bestF = db, f
		}
	}
	return bestDB, bestF
}

// BandEnergyFraction 返回 [lo,hi] 频带功率占全带功率的比例（0..1），
// 用 FFT：声学回环这种"音高有偏移"的场景比定频 Goertzel 稳。
func (w *WAV) BandEnergyFraction(lo, hi float64) float64 {
	n := w.frames()
	if n == 0 || lo >= hi {
		return 0
	}
	// 单声道混音 + 去直流
	x := make([]float64, n)
	ch := float64(w.Channels)
	var mean float64
	for i := range n {
		var s float64
		for c := range w.Channels {
			s += w.Samples[i*w.Channels+c]
		}
		x[i] = s / ch
		mean += x[i]
	}
	mean /= float64(n)
	// Hann 窗 + 朴素 DFT 只在目标频带内算，成本可控（带内 bin 少）。
	bandPower, totalPower := 0.0, 0.0
	binHz := float64(w.SampleRate) / float64(n)
	for i := range n {
		x[i] = (x[i] - mean) * (0.5 - 0.5*math.Cos(2*math.Pi*float64(i)/float64(n-1)))
		totalPower += x[i] * x[i]
	}
	for f := math.Max(lo, binHz); f <= hi; f += binHz {
		w0 := 2 * math.Pi * f / float64(w.SampleRate)
		var re, im float64
		for i, v := range x {
			re += v * math.Cos(w0*float64(i))
			im -= v * math.Sin(w0*float64(i))
		}
		bandPower += re*re + im*im
	}
	if totalPower == 0 {
		return 0
	}
	// 单边谱：一个 bin 的功率 ≈ 2*(re²+im²)/N，而 totalPower 是 N 个样本的平方和。
	return math.Min(1, 2*bandPower/float64(n)/totalPower)
}
