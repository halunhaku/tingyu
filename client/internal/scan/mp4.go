package scan

// MP4 (M4A/ALAC) metadata: duration from the movie header, tags from the
// iTunes-style ilst metadata. The cover is the covr atom. Parsing is bounded:
// only the moov box is read, never the audio payload.

import (
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"time"
)

// boxHeader describes one ISO base media file box.
type boxHeader struct {
	size   int64
	typ    string
	header int64
}

// readBoxHeader reads a box header at offset. size 0 means "to end of file",
// size 1 means a 64-bit size follows.
func readBoxHeader(r io.ReaderAt, offset, limit int64) (boxHeader, error) {
	var buf [16]byte
	if err := readAt(r, offset, buf[:8]); err != nil {
		return boxHeader{}, err
	}
	size := int64(binary.BigEndian.Uint32(buf[0:4]))
	typ := string(buf[4:8])
	header := int64(8)
	if size == 1 {
		if err := readAt(r, offset+8, buf[8:16]); err != nil {
			return boxHeader{}, err
		}
		size = int64(binary.BigEndian.Uint64(buf[8:16]))
		header = 16
	} else if size == 0 {
		size = limit - offset
	}
	if size < header || offset+size > limit {
		return boxHeader{}, fmt.Errorf("scan: MP4 box %q at %d has size %d", typ, offset, size)
	}
	return boxHeader{size: size, typ: typ, header: header}, nil
}

// readMP4 finds moov, reads the duration from mvhd and the tags from ilst.
func readMP4(file *os.File) (Meta, error) {
	info, err := file.Stat()
	if err != nil {
		return Meta{}, err
	}
	size := info.Size()
	moovOffset, moovSize, err := findTopBox(file, size, "moov")
	if err != nil {
		return Meta{}, err
	}
	moov, err := readBytes(file, moovOffset, moovSize)
	if err != nil {
		return Meta{}, err
	}
	meta := parseMoov(moov)
	return meta, nil
}

// findTopBox scans the top level for typ.
func findTopBox(r io.ReaderAt, size int64, typ string) (int64, int64, error) {
	for offset := int64(0); offset+8 <= size; {
		box, err := readBoxHeader(r, offset, size)
		if err != nil {
			// A broken box: stop rather than loop forever.
			return 0, 0, errUnsupportedFormat
		}
		if box.typ == typ {
			return offset + box.header, box.size - box.header, nil
		}
		offset += box.size
	}
	return 0, 0, errUnsupportedFormat
}

// parseMoov walks the moov payload.
func parseMoov(moov []byte) Meta {
	var meta Meta
	var tags map[string][]byte
	var genres []string
	walkBoxes(moov, func(box boxHeader, payload []byte) {
		switch box.typ {
		case "mvhd":
			meta.Duration, _ = parseMVHD(payload)
		case "trak":
			walkBoxes(payload, func(child boxHeader, childPayload []byte) {
				if child.typ == "mdia" {
					walkBoxes(childPayload, func(md boxHeader, mdPayload []byte) {
						if md.typ == "mdhd" && meta.Duration == 0 {
							meta.Duration, _ = parseMDHD(mdPayload)
						}
					})
				}
			})
		case "udta":
			walkBoxes(payload, func(child boxHeader, childPayload []byte) {
				if child.typ == "meta" {
					if ilst := findMetaIlst(childPayload); ilst != nil {
						tags, genres = parseIlst(ilst)
					}
				}
			})
		case "meta":
			if ilst := findMetaIlst(payload); ilst != nil {
				tags, genres = parseIlst(ilst)
			}
		}
	})
	if tags != nil {
		applyIlst(&meta, tags, genres)
	}
	return meta
}

// walkBoxes iterates the children in one payload.
func walkBoxes(payload []byte, fn func(box boxHeader, body []byte)) {
	for offset := int64(0); offset+8 <= int64(len(payload)); {
		box, err := readBoxBytes(payload, offset)
		if err != nil {
			return
		}
		body := payload[offset+box.header : offset+box.size]
		fn(box, body)
		offset += box.size
	}
}

func readBoxBytes(payload []byte, offset int64) (boxHeader, error) {
	if offset+8 > int64(len(payload)) {
		return boxHeader{}, io.ErrUnexpectedEOF
	}
	size := int64(binary.BigEndian.Uint32(payload[offset : offset+4]))
	typ := string(payload[offset+4 : offset+8])
	header := int64(8)
	if size == 1 {
		if offset+16 > int64(len(payload)) {
			return boxHeader{}, io.ErrUnexpectedEOF
		}
		size = int64(binary.BigEndian.Uint64(payload[offset+8 : offset+16]))
		header = 16
	} else if size == 0 {
		size = int64(len(payload)) - offset
	}
	if size < header || offset+size > int64(len(payload)) {
		return boxHeader{}, io.ErrUnexpectedEOF
	}
	return boxHeader{size: size, typ: typ, header: header}, nil
}

func parseMVHD(payload []byte) (time.Duration, int) {
	if len(payload) < 20 {
		return 0, 0
	}
	version := payload[0]
	if version == 1 {
		if len(payload) < 32 {
			return 0, 0
		}
		timescale := binary.BigEndian.Uint32(payload[20:24])
		duration := binary.BigEndian.Uint64(payload[24:32])
		return scaleDuration(duration, timescale)
	}
	timescale := binary.BigEndian.Uint32(payload[12:16])
	duration := uint64(binary.BigEndian.Uint32(payload[16:20]))
	return scaleDuration(duration, timescale)
}

func parseMDHD(payload []byte) (time.Duration, int) {
	if len(payload) < 20 {
		return 0, 0
	}
	if payload[0] == 1 {
		if len(payload) < 32 {
			return 0, 0
		}
		timescale := binary.BigEndian.Uint32(payload[20:24])
		duration := binary.BigEndian.Uint64(payload[24:32])
		return scaleDuration(duration, timescale)
	}
	timescale := binary.BigEndian.Uint32(payload[12:16])
	duration := uint64(binary.BigEndian.Uint32(payload[16:20]))
	return scaleDuration(duration, timescale)
}

func scaleDuration(duration uint64, timescale uint32) (time.Duration, int) {
	if timescale == 0 {
		return 0, 0
	}
	seconds := float64(duration) / float64(timescale)
	return time.Duration(seconds * float64(time.Second)), int(timescale)
}

// findMetaIlst skips the full-box version/flags of meta and returns ilst.
func findMetaIlst(metaPayload []byte) []byte {
	if len(metaPayload) < 4 {
		return nil
	}
	body := metaPayload[4:]
	var ilst []byte
	walkBoxes(body, func(box boxHeader, payload []byte) {
		if box.typ == "ilst" {
			ilst = payload
		}
	})
	return ilst
}

// parseIlst returns the tag payloads by atom type, plus numeric genres.
func parseIlst(ilst []byte) (map[string][]byte, []string) {
	tags := make(map[string][]byte)
	var genres []string
	walkBoxes(ilst, func(box boxHeader, payload []byte) {
		var value []byte
		walkBoxes(payload, func(child boxHeader, childPayload []byte) {
			if child.typ == "data" && len(childPayload) >= 8 {
				value = childPayload[8:]
			}
		})
		if value == nil {
			return
		}
		if box.typ == "gnre" && len(value) >= 2 {
			// gnre is 1-based in the ID3v1 genre list.
			genres = append(genres, genreName(int(binary.BigEndian.Uint16(value[:2]))-1))
			return
		}
		tags[box.typ] = append([]byte(nil), value...)
	})
	return tags, genres
}

func applyIlst(meta *Meta, tags map[string][]byte, genres []string) {
	text := func(key string) string { return nonEmpty(string(tags[key])) }
	meta.Title = text("\xa9nam")
	meta.Artist = text("\xa9ART")
	meta.Album = text("\xa9alb")
	meta.Genre = text("\xa9gen")
	if meta.Genre == "" && len(genres) > 0 {
		meta.Genre = genres[0]
	}
	meta.Lyrics = text("\xa9lyr")
	meta.Year = parseYear(text("\xa9day"))
	if raw := tags["trkn"]; len(raw) >= 4 {
		meta.TrackNumber = int(binary.BigEndian.Uint16(raw[2:4]))
	}
	if raw := tags["disk"]; len(raw) >= 4 {
		meta.DiscNumber = int(binary.BigEndian.Uint16(raw[2:4]))
	}
	if raw, ok := tags["covr"]; ok && len(raw) > 0 {
		meta.Picture = raw
	}
}
