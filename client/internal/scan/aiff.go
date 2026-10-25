package scan

// AIFF/AIFC: FORM chunks. Duration is COMM's frame count over its sample
// rate; tags are NAME/AUTH/ANNO text chunks and an optional ID3 chunk.

import (
	"encoding/binary"
	"io"
	"math"
	"os"
	"strings"
	"time"
)

func readAIFF(file *os.File) (Meta, error) {
	info, err := file.Stat()
	if err != nil {
		return Meta{}, err
	}
	size := info.Size()
	var header [12]byte
	if err := readAt(file, 0, header[:]); err != nil {
		return Meta{}, err
	}
	if string(header[0:4]) != "FORM" {
		return Meta{}, errUnsupportedFormat
	}
	kind := string(header[8:12])
	if kind != "AIFF" && kind != "AIFC" {
		return Meta{}, errUnsupportedFormat
	}
	var meta Meta
	var frames uint32
	var sampleRate float64
	offset := int64(12)
	for offset+8 <= size {
		var chunk [8]byte
		if err := readAt(file, offset, chunk[:]); err != nil {
			break
		}
		id := string(chunk[0:4])
		length := int64(binary.BigEndian.Uint32(chunk[4:8]))
		body := offset + 8
		if length < 0 || body+length > size {
			length = size - body
		}
		switch id {
		case "COMM":
			if length >= 18 {
				block, err := readBytes(file, body, length)
				if err != nil {
					return Meta{}, err
				}
				_ = binary.BigEndian.Uint16(block[0:2]) // channels
				frames = binary.BigEndian.Uint32(block[2:6])
				sampleRate = extended80(block[8:18])
			}
		case "NAME":
			if meta.Title == "" {
				meta.Title = readChunkText(file, body, length)
			}
		case "AUTH":
			if meta.Artist == "" {
				meta.Artist = readChunkText(file, body, length)
			}
		case "ANNO":
			if meta.Album == "" {
				meta.Album = readChunkText(file, body, length)
			}
		case "ID3 ", "id3 ":
			block, err := readBytes(file, body, length)
			if err != nil {
				return Meta{}, err
			}
			applyID3Tags(&meta, parseID3TagBytes(block))
		}
		offset = body + length
		if length%2 == 1 {
			offset++
		}
	}
	if sampleRate > 0 && frames > 0 {
		meta.SampleRate = int(math.Round(sampleRate))
		seconds := float64(frames) / sampleRate
		meta.Duration = time.Duration(seconds * float64(time.Second))
	}
	return meta, nil
}

func readChunkText(r io.ReaderAt, offset, length int64) string {
	block, err := readBytes(r, offset, length)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(strings.Trim(string(block), "\x00"))
}

// extended80 decodes the 80-bit IEEE 754 extended float AIFF uses for sample
// rates (sign/exponent 15 bits, explicit-integer 64-bit mantissa).
func extended80(b []byte) float64 {
	if len(b) < 10 {
		return 0
	}
	sign := 1.0
	if b[0]&0x80 != 0 {
		sign = -1
	}
	exponent := int(b[0]&0x7f)<<8 | int(b[1])
	mantissa := binary.BigEndian.Uint64(b[2:10])
	if exponent == 0 && mantissa == 0 {
		return 0
	}
	// The mantissa includes the integer bit: value = mantissa/2^63 * 2^(exp-16383).
	return sign * float64(mantissa) / math.Ldexp(1, 63) * math.Ldexp(1, exponent-16383)
}
