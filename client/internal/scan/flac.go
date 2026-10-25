package scan

import (
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"os"
	"strings"
	"time"
)

// readFLAC parses a native FLAC stream: STREAMINFO for duration, VORBIS_COMMENT
// for tags, PICTURE for the cover. Duration is exact here (total samples and
// sample rate are in STREAMINFO), which is what M1's FLAC acceptance relies on.
func readFLAC(file *os.File) (Meta, error) {
	var header [4]byte
	if err := readAt(file, 0, header[:]); err != nil {
		return Meta{}, err
	}
	if string(header[:]) != "fLaC" {
		return Meta{}, errUnsupportedFormat
	}
	var meta Meta
	var comments map[string][]string
	offset := int64(4)
	for {
		var blockHeader [4]byte
		if err := readAt(file, offset, blockHeader[:]); err != nil {
			return meta, err
		}
		last := blockHeader[0]&0x80 != 0
		blockType := blockHeader[0] & 0x7f
		length := int64(blockHeader[1])<<16 | int64(blockHeader[2])<<8 | int64(blockHeader[3])
		offset += 4
		if length < 0 || length > maxTagBytes {
			return meta, fmt.Errorf("scan: FLAC metadata block of %d bytes", length)
		}
		if blockType == 0 { // STREAMINFO, always 34 bytes
			block, err := readBytes(file, offset, length)
			if err != nil {
				return meta, err
			}
			meta.SampleRate, meta.Duration = flacStreamInfo(block)
		} else if blockType == 4 || blockType == 6 {
			block, err := readBytes(file, offset, length)
			if err != nil {
				return meta, err
			}
			switch blockType {
			case 4:
				comments = parseVorbisComments(block)
			case 6:
				if meta.Picture == nil {
					meta.Picture = flacPictureData(block)
				}
			}
		}
		offset += length
		if last {
			break
		}
	}
	if len(comments) > 0 {
		applyComments(&meta, comments)
	}
	return meta, nil
}

// flacStreamInfo returns the sample rate and the exact duration. Layout after
// the fixed 10-byte prefix: 20 bits sample rate, 3 channels-1, 5 bits-1,
// 36 total samples (RFC 9639 §8.2).
func flacStreamInfo(block []byte) (int, time.Duration) {
	if len(block) < 18 {
		return 0, 0
	}
	v := binary.BigEndian.Uint64(block[10:18])
	sampleRate := int(v >> 44)
	totalSamples := v & (1<<36 - 1)
	if sampleRate <= 0 {
		return 0, 0
	}
	seconds := float64(totalSamples) / float64(sampleRate)
	return sampleRate, time.Duration(seconds * float64(time.Second))
}

// parseVorbisComments parses the shared Vorbis comment block: vendor length,
// vendor, count, then length-prefixed KEY=value entries (all little-endian).
func parseVorbisComments(block []byte) map[string][]string {
	if len(block) < 8 {
		return nil
	}
	vendorLen := int(binary.LittleEndian.Uint32(block[0:4]))
	if vendorLen < 0 || 4+vendorLen+4 > len(block) {
		return nil
	}
	offset := 4 + vendorLen
	count := int(binary.LittleEndian.Uint32(block[offset : offset+4]))
	offset += 4
	if count < 0 || count > 100_000 {
		return nil
	}
	out := make(map[string][]string, count)
	for range count {
		if offset+4 > len(block) {
			return out
		}
		length := int(binary.LittleEndian.Uint32(block[offset : offset+4]))
		offset += 4
		if length < 0 || offset+length > len(block) {
			return out
		}
		entry := string(block[offset : offset+length])
		offset += length
		key, value, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		key = strings.ToUpper(strings.TrimSpace(key))
		out[key] = append(out[key], value)
	}
	return out
}

// applyComments maps Vorbis comments onto Meta. Later entries lose to the
// first one, like the tag readers the Flutter client uses.
func applyComments(meta *Meta, comments map[string][]string) {
	first := func(keys ...string) string {
		for _, key := range keys {
			if values := comments[key]; len(values) > 0 {
				if value := nonEmpty(values[0]); value != "" {
					return value
				}
			}
		}
		return ""
	}
	meta.Title = first("TITLE")
	meta.Artist = first("ARTIST", "ALBUMARTIST")
	meta.Album = first("ALBUM")
	meta.Genre = first("GENRE")
	meta.Lyrics = first("LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS")
	if values := comments["TRACKNUMBER"]; len(values) > 0 {
		meta.TrackNumber, _ = parsePair(values[0])
	}
	if values := comments["DISCNUMBER"]; len(values) > 0 {
		meta.DiscNumber, _ = parsePair(values[0])
	}
	meta.Year = parseYear(first("DATE", "YEAR"))
	if meta.Picture == nil {
		if values := comments["METADATA_BLOCK_PICTURE"]; len(values) > 0 {
			if raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(values[0])); err == nil {
				meta.Picture = flacPictureData(raw)
			}
		} else if values := comments["COVERART"]; len(values) > 0 {
			if raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(values[0])); err == nil {
				meta.Picture = raw
			}
		}
	}
}

// flacPictureData extracts the image bytes from a PICTURE block: type (4),
// MIME length (4) + MIME, description length (4) + description, width,
// height, depth, colors (16), data length (4) + data.
func flacPictureData(block []byte) []byte {
	if len(block) < 8 {
		return nil
	}
	offset := 4 // picture type
	mimeLen := int(binary.BigEndian.Uint32(block[offset : offset+4]))
	offset += 4
	if mimeLen < 0 || offset+mimeLen+4 > len(block) {
		return nil
	}
	offset += mimeLen
	descLen := int(binary.BigEndian.Uint32(block[offset : offset+4]))
	offset += 4
	if descLen < 0 || offset+descLen+16+4 > len(block) {
		return nil
	}
	offset += descLen + 16
	dataLen := int(binary.BigEndian.Uint32(block[offset : offset+4]))
	offset += 4
	if dataLen <= 0 || offset+dataLen > len(block) {
		return nil
	}
	data := make([]byte, dataLen)
	copy(data, block[offset:offset+dataLen])
	return data
}
