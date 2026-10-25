package scan

// Bare ADTS AAC: no tag container of its own, so metadata is the ID3v2 tag at
// the start when present. Duration counts ADTS frames (1024 samples each).

import (
	"os"
)

var adtsSampleRates = []int{96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350}

func readAAC(file *os.File) (Meta, error) {
	tags, audioStart, _ := readID3v2(file)
	info, err := file.Stat()
	if err != nil {
		return Meta{}, err
	}
	size := info.Size()
	var meta Meta
	applyID3Tags(&meta, tags)
	offset := audioStart
	frames := uint64(0)
	sampleRate := 0
	var buf [7]byte
	for offset+7 <= size {
		if err := readAt(file, offset, buf[:]); err != nil {
			break
		}
		if buf[0] != 0xFF || buf[1]&0xF0 != 0xF0 {
			break
		}
		protectionAbsent := buf[1] & 0x01
		rateIndex := int((buf[2] >> 2) & 0x0F)
		if rateIndex >= len(adtsSampleRates) {
			break
		}
		frameLength := int(buf[3]&0x03)<<11 | int(buf[4])<<3 | int(buf[5]>>5)
		if frameLength < 7 {
			break
		}
		if sampleRate == 0 {
			sampleRate = adtsSampleRates[rateIndex]
		}
		frames++
		offset += int64(frameLength)
		if protectionAbsent == 0 {
			// CRC present: the frame length already includes it; nothing to do.
		}
	}
	meta.SampleRate = sampleRate
	if frames > 0 {
		meta.Duration = durationFromFrames(frames, 1024, sampleRate)
	}
	if meta.Duration > 0 {
		meta.Bitrate = int(float64(size-audioStart) * 8 / meta.Duration.Seconds() / 1000)
	}
	if meta.Duration == 0 {
		return meta, errUnsupportedFormat
	}
	return meta, nil
}
