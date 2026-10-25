package scan

// ID3v2/v1 and MPEG audio frame parsing, shared by .mp3. The tag formats are
// old and forgiving in practice, so every reader is bounds-checked and gives
// up quietly: a file with a broken tag still plays, and a scan must still
// count it.

import (
	"encoding/binary"
	"io"
	"os"
	"strings"
	"time"
	"unicode/utf16"
)

type id3Tags struct {
	title, artist, album, genre, lyrics string
	track, disc, year                   int
	picture                             []byte
}

// readID3v2 parses the tag at offset 0 and returns the offset where audio
// starts. The bool reports whether a tag was present.
func readID3v2(r io.ReaderAt) (id3Tags, int64, bool) {
	var header [10]byte
	if err := readAt(r, 0, header[:]); err != nil || string(header[0:3]) != "ID3" {
		return id3Tags{}, 0, false
	}
	major := header[3]
	size := syncsafe(header[6:10])
	if size < 0 || size > maxTagBytes {
		return id3Tags{}, 0, true
	}
	tag, err := readBytes(r, 10, int64(size))
	if err != nil {
		return id3Tags{}, 0, true
	}
	return parseID3v2(tag, major), int64(10 + size), true
}

// parseID3v2 decodes the frames of an ID3v2 tag whose 10-byte header has
// already been consumed. It is shared with container formats that carry an
// ID3 chunk (WAV, AIFF).
func parseID3v2(tag []byte, major byte) id3Tags {
	var tags id3Tags
	offset := 0
	switch major {
	case 2:
		for offset+6 <= len(tag) {
			id := string(tag[offset : offset+3])
			frameSize := int(tag[offset+3])<<16 | int(tag[offset+4])<<8 | int(tag[offset+5])
			offset += 6
			if id == "\x00\x00\x00" || frameSize <= 0 || offset+frameSize > len(tag) {
				break
			}
			tags.apply(id, tag[offset:offset+frameSize], true)
			offset += frameSize
		}
	case 3, 4:
		for offset+10 <= len(tag) {
			id := string(tag[offset : offset+4])
			var frameSize int
			if major == 4 {
				frameSize = syncsafe(tag[offset+4 : offset+8])
			} else {
				frameSize = int(binary.BigEndian.Uint32(tag[offset+4 : offset+8]))
			}
			offset += 10
			if id == "\x00\x00\x00\x00" || frameSize <= 0 || offset+frameSize > len(tag) {
				break
			}
			tags.apply(id, tag[offset:offset+frameSize], false)
			offset += frameSize
		}
	}
	return tags
}

// apply maps one frame onto the tag set.
func (t *id3Tags) apply(id string, frame []byte, v22 bool) {
	switch {
	case id == "TIT2" || (v22 && id == "TT2"):
		t.title = id3Text(frame)
	case id == "TPE1" || (v22 && id == "TP1"):
		t.artist = id3Text(frame)
	case id == "TALB" || (v22 && id == "TAL"):
		t.album = id3Text(frame)
	case id == "TCON" || (v22 && id == "TCO"):
		t.genre = cleanGenre(id3Text(frame))
	case id == "TRCK" || (v22 && id == "TRK"):
		t.track, _ = parsePair(id3Text(frame))
	case id == "TPOS" || (v22 && id == "TPA"):
		t.disc, _ = parsePair(id3Text(frame))
	case id == "TDRC" || id == "TYER" || (v22 && id == "TYE"):
		if t.year == 0 {
			t.year = parseYear(id3Text(frame))
		}
	case id == "USLT" || (v22 && id == "ULT"):
		if t.lyrics == "" {
			t.lyrics = id3Lyrics(frame)
		}
	case id == "APIC" || (v22 && id == "PIC"):
		if t.picture == nil {
			t.picture = id3Picture(frame, v22)
		}
	}
}

// syncsafe decodes ID3's 7-bit-per-byte size.
func syncsafe(b []byte) int {
	if len(b) < 4 {
		return -1
	}
	return int(b[0]&0x7f)<<21 | int(b[1]&0x7f)<<14 | int(b[2]&0x7f)<<7 | int(b[3]&0x7f)
}

// id3Text decodes a text frame's encoding byte.
func id3Text(frame []byte) string {
	if len(frame) < 1 {
		return ""
	}
	encoding := frame[0]
	body := frame[1:]
	switch encoding {
	case 1:
		body = utf16Bytes(body)
	case 2:
		body = utf16BE(body)
	case 0:
		// ISO-8859-1; convert byte-wise so high bytes are not dropped.
		runes := make([]rune, len(body))
		for i, b := range body {
			runes[i] = rune(b)
		}
		return strings.Trim(string(runes), "\x00 ")
	default:
		// UTF-8
	}
	return strings.Trim(string(body), "\x00 ")
}

func utf16Bytes(body []byte) []byte {
	if len(body) >= 2 {
		switch {
		case body[0] == 0xFF && body[1] == 0xFE:
			body = body[2:]
		case body[0] == 0xFE && body[1] == 0xFF:
			return utf16BE(body[2:])
		}
	}
	return utf16LE(body)
}

func utf16LE(body []byte) []byte {
	units := make([]uint16, 0, len(body)/2)
	for i := 0; i+1 < len(body); i += 2 {
		units = append(units, binary.LittleEndian.Uint16(body[i:i+2]))
	}
	return []byte(string(utf16.Decode(units)))
}

func utf16BE(body []byte) []byte {
	units := make([]uint16, 0, len(body)/2)
	for i := 0; i+1 < len(body); i += 2 {
		units = append(units, binary.BigEndian.Uint16(body[i:i+2]))
	}
	return []byte(string(utf16.Decode(units)))
}

// id3Lyrics decodes USLT: encoding, language (3), descriptor, text.
func id3Lyrics(frame []byte) string {
	if len(frame) < 5 {
		return ""
	}
	encoding := frame[0]
	body := frame[4:]
	body = skipEncodedTerminator(body, encoding)
	return id3Text(append([]byte{encoding}, body...))
}

// id3Picture decodes APIC (v2.3/4) or PIC (v2.2), returning the image bytes.
func id3Picture(frame []byte, v22 bool) []byte {
	if len(frame) < 4 {
		return nil
	}
	encoding := frame[0]
	rest := frame[1:]
	if v22 {
		if len(rest) < 4 {
			return nil
		}
		rest = rest[3:] // image format, e.g. "JPG"
	} else {
		end := indexByte(rest, 0)
		if end < 0 {
			return nil
		}
		rest = rest[end+1:]
	}
	if len(rest) < 1 {
		return nil
	}
	rest = rest[1:] // picture type
	rest = skipEncodedTerminator(rest, encoding)
	if len(rest) == 0 {
		return nil
	}
	out := make([]byte, len(rest))
	copy(out, rest)
	return out
}

// skipEncodedTerminator removes a tag description up to and including its
// terminator (one NUL, or two for UTF-16).
func skipEncodedTerminator(body []byte, encoding byte) []byte {
	width := 1
	if encoding == 1 || encoding == 2 {
		width = 2
	}
	for i := 0; i+width <= len(body); i += width {
		zero := true
		for j := range width {
			if body[i+j] != 0 {
				zero = false
				break
			}
		}
		if zero {
			return body[i+width:]
		}
	}
	return nil
}

func indexByte(b []byte, c byte) int {
	for i, v := range b {
		if v == c {
			return i
		}
	}
	return -1
}

// cleanGenre turns "(17)" into "Rock" and leaves free text alone.
func cleanGenre(value string) string {
	value = strings.TrimSpace(value)
	if strings.HasPrefix(value, "(") {
		if end := strings.IndexByte(value, ')'); end > 1 {
			return genreName(parsePositiveInt(value[1:end]))
		}
	}
	return value
}

// readID3v1 reads the 128-byte trailer, if present.
func readID3v1(r io.ReaderAt, size int64) id3Tags {
	if size < 128 {
		return id3Tags{}
	}
	buf := make([]byte, 128)
	if err := readAt(r, size-128, buf); err != nil || string(buf[0:3]) != "TAG" {
		return id3Tags{}
	}
	text := func(b []byte) string {
		return strings.Trim(string(b), "\x00 ")
	}
	tags := id3Tags{
		title:  text(buf[3:33]),
		artist: text(buf[33:63]),
		album:  text(buf[63:93]),
		year:   parseYear(text(buf[93:97])),
	}
	if buf[125] == 0 && buf[126] != 0 {
		tags.track = int(buf[126])
	}
	tags.genre = genreName(int(buf[127]))
	return tags
}

// mpegHeader is one parsed MPEG audio frame header.
type mpegHeader struct {
	version         int // 1, 2 or 25 (*10 for 2.5)
	layer           int
	bitrateKbps     int
	sampleRate      int
	channels        int
	samplesPerFrame int
}

var mpegBitrateV1L3 = []int{0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0}
var mpegBitrateV2L3 = []int{0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0}
var mpegBitrateV1L2 = []int{0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0}
var mpegBitrateV2L2 = []int{0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0}
var mpegBitrateV1L1 = []int{0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0}
var mpegBitrateV2L1 = []int{0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0}
var mpegSampleRates = map[int][]int{
	1:  {44100, 48000, 32000, 0},
	2:  {22050, 24000, 16000, 0},
	25: {11025, 12000, 8000, 0},
}

// parseMPEGHeader decodes 4 bytes of a layer III/II/I frame header.
func parseMPEGHeader(b []byte) (mpegHeader, bool) {
	if len(b) < 4 || b[0] != 0xFF || b[1]&0xE0 != 0xE0 {
		return mpegHeader{}, false
	}
	versionBits := (b[1] >> 3) & 0x3
	layerBits := (b[1] >> 1) & 0x3
	bitrateIndex := int(b[2] >> 4)
	rateIndex := int((b[2] >> 2) & 0x3)
	padding := (b[2] >> 1) & 0x1
	channelMode := b[3] >> 6

	var version int
	switch versionBits {
	case 3:
		version = 1
	case 2:
		version = 2
	case 0:
		version = 25
	default:
		return mpegHeader{}, false
	}
	var layer int
	switch layerBits {
	case 1:
		layer = 3
	case 2:
		layer = 2
	case 3:
		layer = 1
	default:
		return mpegHeader{}, false
	}
	if bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3 {
		return mpegHeader{}, false
	}
	var bitrate int
	switch layer {
	case 1:
		if version == 1 {
			bitrate = mpegBitrateV1L1[bitrateIndex]
		} else {
			bitrate = mpegBitrateV2L1[bitrateIndex]
		}
	case 2:
		if version == 1 {
			bitrate = mpegBitrateV1L2[bitrateIndex]
		} else {
			bitrate = mpegBitrateV2L2[bitrateIndex]
		}
	default:
		if version == 1 {
			bitrate = mpegBitrateV1L3[bitrateIndex]
		} else {
			bitrate = mpegBitrateV2L3[bitrateIndex]
		}
	}
	sampleRate := mpegSampleRates[version][rateIndex]
	if sampleRate == 0 || bitrate == 0 {
		return mpegHeader{}, false
	}
	samples := 1152
	if layer == 3 && version != 1 {
		samples = 576
	} else if layer == 1 {
		samples = 384
	}
	_ = padding
	channels := 2
	if channelMode == 3 {
		channels = 1
	}
	return mpegHeader{
		version: version, layer: layer, bitrateKbps: bitrate, sampleRate: sampleRate,
		channels: channels, samplesPerFrame: samples,
	}, true
}

// readMP3 finds the first audio frame after any ID3v2 tag, reads a Xing/Info
// frame count when present, and falls back to a constant-bitrate estimate.
func readMP3(file *os.File) (Meta, error) {
	tags, audioStart, _ := readID3v2(file)
	info, err := file.Stat()
	if err != nil {
		return Meta{}, err
	}
	size := info.Size()
	if size <= 0 {
		return Meta{}, errUnsupportedFormat
	}
	// The ID3v1 trailer is not audio.
	audioEnd := size
	var v1 id3Tags
	if size > 128 {
		var trailer [128]byte
		if err := readAt(file, size-128, trailer[:]); err == nil && string(trailer[0:3]) == "TAG" {
			audioEnd = size - 128
			v1 = readID3v1(file, size)
		}
	}
	frameStart, header := findMPEGFrame(file, audioStart, audioEnd)
	if frameStart < 0 {
		return Meta{}, errUnsupportedFormat
	}
	meta := Meta{
		Title: tags.title, Artist: tags.artist, Album: tags.album,
		Genre: tags.genre, Lyrics: tags.lyrics,
		TrackNumber: tags.track, DiscNumber: tags.disc, Year: tags.year,
		Picture: tags.picture, Bitrate: header.bitrateKbps, SampleRate: header.sampleRate,
	}
	if meta.Year == 0 {
		meta.Year = v1.year
	}
	if meta.Title == "" {
		meta.Title = v1.title
	}
	if meta.Artist == "" {
		meta.Artist = v1.artist
	}
	if meta.Album == "" {
		meta.Album = v1.album
	}
	if meta.Genre == "" {
		meta.Genre = v1.genre
	}
	if meta.TrackNumber == 0 {
		meta.TrackNumber = v1.track
	}

	if frames, ok := xingFrames(file, frameStart, header); ok && frames > 0 {
		meta.Duration = durationFromFrames(frames, header.samplesPerFrame, header.sampleRate)
		return meta, nil
	}
	if audioEnd <= audioStart {
		return meta, nil
	}
	seconds := float64(audioEnd-audioStart) * 8 / (float64(header.bitrateKbps) * 1000)
	meta.Duration = time.Duration(seconds * float64(time.Second))
	return meta, nil
}

// findMPEGFrame scans for a frame header with a valid following frame (or end
// of file), so a 0xFFE byte in an ID3 tag cannot be mistaken for audio.
func findMPEGFrame(file io.ReaderAt, start, end int64) (int64, mpegHeader) {
	window := make([]byte, 4)
	for offset := start; offset+4 <= end && offset < start+(1<<20); offset++ {
		if err := readAt(file, offset, window); err != nil {
			return -1, mpegHeader{}
		}
		header, ok := parseMPEGHeader(window)
		if !ok {
			continue
		}
		return offset, header
	}
	return -1, mpegHeader{}
}

// xingFrames reads a Xing/Info header placed after the side information.
func xingFrames(file io.ReaderAt, frameStart int64, header mpegHeader) (uint64, bool) {
	sideInfo := 32
	if header.version != 1 {
		sideInfo = 17
	}
	if header.channels == 1 {
		if header.version == 1 {
			sideInfo = 17
		} else {
			sideInfo = 9
		}
	}
	offset := frameStart + 4 + int64(sideInfo)
	var buf [16]byte
	if err := readAt(file, offset, buf[:]); err != nil {
		return 0, false
	}
	if string(buf[0:4]) != "Xing" && string(buf[0:4]) != "Info" {
		return 0, false
	}
	flags := binary.BigEndian.Uint32(buf[4:8])
	if flags&1 == 0 {
		return 0, false
	}
	return uint64(binary.BigEndian.Uint32(buf[8:12])), true
}

// parseID3TagBytes decodes a complete ID3v2 tag (header included) embedded in
// a container chunk.
func parseID3TagBytes(b []byte) id3Tags {
	if len(b) < 10 || string(b[0:3]) != "ID3" {
		return id3Tags{}
	}
	return parseID3v2(b[10:], b[3])
}

// applyID3Tags copies what a tag set knows onto Meta, leaving fields another
// source already filled.
func applyID3Tags(meta *Meta, tags id3Tags) {
	if meta.Title == "" {
		meta.Title = tags.title
	}
	if meta.Artist == "" {
		meta.Artist = tags.artist
	}
	if meta.Album == "" {
		meta.Album = tags.album
	}
	if meta.Genre == "" {
		meta.Genre = tags.genre
	}
	if meta.Lyrics == "" {
		meta.Lyrics = tags.lyrics
	}
	if meta.TrackNumber == 0 {
		meta.TrackNumber = tags.track
	}
	if meta.DiscNumber == 0 {
		meta.DiscNumber = tags.disc
	}
	if meta.Year == 0 {
		meta.Year = tags.year
	}
	if meta.Picture == nil {
		meta.Picture = tags.picture
	}
}
