package scan

// Ogg containers: Vorbis, Opus and FLAC-in-Ogg. Tags come from the comment
// packet (Vorbis comments); duration comes from the last page's granule
// position, which is why the file is scanned at both ends instead of decoded.

import (
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

type oggPage struct {
	headerType byte
	granule    int64
	lacing     []byte
	payload    []byte
}

// readOgg reads the page headers needed for the codec and comment packets,
// then the last granule for the duration.
func readOgg(file *os.File) (Meta, error) {
	info, err := file.Stat()
	if err != nil {
		return Meta{}, err
	}
	size := info.Size()
	pages, err := readOggPages(file, 0, size, 16, 4<<20)
	if err != nil || len(pages) == 0 {
		return Meta{}, errUnsupportedFormat
	}
	var meta Meta
	packets := oggPackets(pages)
	if len(packets) == 0 {
		return Meta{}, errUnsupportedFormat
	}
	first := packets[0]
	var sampleRate int
	var preskip uint32
	var kind string
	switch {
	case strings.HasPrefix(string(first), "\x01vorbis"):
		kind = "vorbis"
		if len(first) < 16 {
			return Meta{}, errUnsupportedFormat
		}
		sampleRate = int(binary.LittleEndian.Uint32(first[12:16]))
	case strings.HasPrefix(string(first), "OpusHead"):
		kind = "opus"
		if len(first) < 12 {
			return Meta{}, errUnsupportedFormat
		}
		preskip = uint32(binary.LittleEndian.Uint16(first[10:12]))
		sampleRate = 48000
	case strings.HasPrefix(string(first), "\x7fFLAC"):
		kind = "flac"
		if len(first) < 13+4+18 {
			return Meta{}, errUnsupportedFormat
		}
		// 0x7f"FLAC", major, minor, header packets (2), "fLaC", then the
		// STREAMINFO block (header 4 bytes, 34 bytes body).
		streamInfo := first[13+4:]
		sampleRate, meta.Duration = flacStreamInfo(streamInfo)
	default:
		return Meta{}, errUnsupportedFormat
	}
	meta.SampleRate = sampleRate

	for _, packet := range packets[1:] {
		var comments map[string][]string
		switch {
		case kind == "vorbis" && strings.HasPrefix(string(packet), "\x03vorbis"):
			comments = parseVorbisComments(packet[7:])
		case kind == "opus" && strings.HasPrefix(string(packet), "OpusTags"):
			comments = parseVorbisComments(packet[8:])
		case kind == "flac" && len(packet) > 8:
			// FLAC-in-Ogg carries a metadata block header before the body.
			blockType := packet[0] & 0x7f
			if blockType == 4 {
				comments = parseVorbisComments(packet[4:])
			}
		}
		if comments != nil {
			applyComments(&meta, comments)
		}
	}

	if last, ok := lastOggGranule(file, size); ok && meta.Duration == 0 && sampleRate > 0 {
		samples := last
		if kind == "opus" {
			samples -= int64(preskip)
		}
		if samples > 0 {
			meta.Duration = time.Duration(float64(samples) / float64(sampleRate) * float64(time.Second))
		}
	}
	return meta, nil
}

// readOggPages reads up to maxPages pages (at most maxBytes of payload).
func readOggPages(r io.ReaderAt, offset, limit int64, maxPages int, maxBytes int64) ([]oggPage, error) {
	pages := make([]oggPage, 0, maxPages)
	var read int64
	for len(pages) < maxPages && offset+27 <= limit && read < maxBytes {
		var header [27]byte
		if err := readAt(r, offset, header[:]); err != nil {
			break
		}
		if string(header[0:4]) != "OggS" || header[4] != 0 {
			return nil, fmt.Errorf("scan: not an Ogg page at %d", offset)
		}
		segments := int(header[26])
		table := make([]byte, segments)
		if err := readAt(r, offset+27, table); err != nil {
			break
		}
		length := 0
		for _, lacing := range table {
			length += int(lacing)
		}
		payload, err := readBytes(r, offset+27+int64(segments), int64(length))
		if err != nil {
			break
		}
		pages = append(pages, oggPage{
			headerType: header[5],
			granule:    int64(binary.LittleEndian.Uint64(header[6:14])),
			lacing:     table,
			payload:    payload,
		})
		read += int64(length)
		offset += 27 + int64(segments) + int64(length)
	}
	return pages, nil
}

// oggPackets reassembles packets from page segment tables. A segment shorter
// than 255 ends a packet; 255 means it continues in the next segment (and
// possibly the next page).
func oggPackets(pages []oggPage) [][]byte {
	var packets [][]byte
	var current []byte
	for _, page := range pages {
		offset := 0
		for _, lacing := range page.lacing {
			length := int(lacing)
			if offset+length > len(page.payload) {
				return packets
			}
			current = append(current, page.payload[offset:offset+length]...)
			offset += length
			if lacing < 255 {
				packets = append(packets, current)
				current = nil
			}
		}
	}
	if len(current) > 0 {
		packets = append(packets, current)
	}
	return packets
}

// lastOggGranule finds the final complete page by scanning the tail.
func lastOggGranule(r io.ReaderAt, size int64) (int64, bool) {
	const tail = 64 << 10
	start := size - tail
	if start < 0 {
		start = 0
	}
	buf, err := readBytes(r, start, size-start)
	if err != nil || len(buf) < 27 {
		return 0, false
	}
	best := int64(-1)
	for i := 0; i+27 <= len(buf); i++ {
		if buf[i] != 'O' || string(buf[i:i+4]) != "OggS" {
			continue
		}
		granule := int64(binary.LittleEndian.Uint64(buf[i+6 : i+14]))
		if granule >= 0 {
			best = granule
		}
	}
	return best, best >= 0
}
