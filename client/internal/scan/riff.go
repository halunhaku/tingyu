package scan

// WAV: RIFF chunks. Duration is dataSize / byteRate (exact for PCM), tags
// come from a LIST/INFO block and, when present, an ID3 chunk.

import (
	"encoding/binary"
	"os"
	"strings"
	"time"
)

func readWAV(file *os.File) (Meta, error) {
	info, err := file.Stat()
	if err != nil {
		return Meta{}, err
	}
	size := info.Size()
	var header [12]byte
	if err := readAt(file, 0, header[:]); err != nil {
		return Meta{}, err
	}
	if string(header[0:4]) != "RIFF" || string(header[8:12]) != "WAVE" {
		return Meta{}, errUnsupportedFormat
	}
	var meta Meta
	var byteRate uint32
	var dataSize int64
	offset := int64(12)
	for offset+8 <= size {
		var chunk [8]byte
		if err := readAt(file, offset, chunk[:]); err != nil {
			break
		}
		id := string(chunk[0:4])
		length := int64(binary.LittleEndian.Uint32(chunk[4:8]))
		body := offset + 8
		if length < 0 || body+length > size {
			// Streaming WAVs write 0xFFFFFFFF; take what is there.
			length = size - body
		}
		switch id {
		case "fmt ":
			if length >= 16 {
				block, err := readBytes(file, body, length)
				if err != nil {
					return Meta{}, err
				}
				byteRate = binary.LittleEndian.Uint32(block[8:12])
				meta.SampleRate = int(binary.LittleEndian.Uint32(block[4:8]))
			}
		case "data":
			dataSize = length
		case "LIST":
			if length >= 4 {
				block, err := readBytes(file, body, length)
				if err != nil {
					return Meta{}, err
				}
				if string(block[0:4]) == "INFO" {
					applyRIFFInfo(&meta, block[4:])
				}
			}
		case "id3 ", "ID3 ":
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
	if meta.SampleRate > 0 && byteRate > 0 && dataSize > 0 {
		seconds := float64(dataSize) / float64(byteRate)
		meta.Duration = time.Duration(seconds * float64(time.Second))
		meta.Bitrate = int(float64(byteRate) * 8 / 1000)
	}
	return meta, nil
}

// applyRIFFInfo reads the INFO subchunks used for music.
func applyRIFFInfo(meta *Meta, block []byte) {
	offset := 0
	for offset+8 <= len(block) {
		id := string(block[offset : offset+4])
		length := int(binary.LittleEndian.Uint32(block[offset+4 : offset+8]))
		offset += 8
		if length < 0 || offset+length > len(block) {
			return
		}
		value := strings.Trim(string(block[offset:offset+length]), "\x00 ")
		switch id {
		case "INAM":
			if meta.Title == "" {
				meta.Title = value
			}
		case "IART":
			if meta.Artist == "" {
				meta.Artist = value
			}
		case "IPRD":
			if meta.Album == "" {
				meta.Album = value
			}
		case "ICRD":
			if meta.Year == 0 {
				meta.Year = parseYear(value)
			}
		case "IGNR":
			if meta.Genre == "" {
				meta.Genre = value
			}
		}
		offset += length
		if length%2 == 1 {
			offset++
		}
	}
}
