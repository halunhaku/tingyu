// Package scan turns a directory of audio files into library.ScanTrack facts.
//
// It is the Go counterpart of app/lib/sources/local/local_library_scanner.dart
// and keeps its contract (plan §2.1 #2): walk without following symlinks, skip
// dot entries, accept the same nine extensions case-insensitively, cap the
// file count, report progress, and treat a scan as authoritative only when
// nothing was skipped, truncated or cancelled.
//
// Metadata is read here, not by the player: a scan has to work before anything
// plays, and it must skip files whose size and mtime did not change.
package scan

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// SupportedExtensions are the formats the Flutter client accepts
// (local_library_scanner.dart:50). libmpv decodes all of them.
var SupportedExtensions = map[string]bool{
	"mp3": true, "flac": true, "m4a": true, "aac": true, "wav": true,
	"ogg": true, "opus": true, "aiff": true, "alac": true,
}

// MaxFiles caps one scan so a mistyped root does not exhaust memory.
const MaxFiles = 5000

// maxTagBytes bounds one metadata region read (an ID3 tag or cover can be
// large, but never unbounded).
const maxTagBytes = 32 << 20

// Meta is everything a file's tags say. Zero values mean "unknown".
type Meta struct {
	Title       string
	Artist      string
	Album       string
	Duration    time.Duration
	TrackNumber int
	DiscNumber  int
	Year        int
	Genre       string
	Bitrate     int
	SampleRate  int
	Lyrics      string
	Picture     []byte
}

// errUnsupportedFormat reports a container no parser here understands. It is
// not a scan failure: the file is kept with its name and file facts, and
// metadata enrichment (M5) can fill it in later, exactly like the Dart
// scanner's catch-all.
var errUnsupportedFormat = errors.New("scan: unsupported or unreadable metadata")

// ReadMeta parses path according to its extension.
func ReadMeta(path string) (Meta, error) {
	file, err := os.Open(path)
	if err != nil {
		return Meta{}, err
	}
	defer file.Close()
	switch strings.ToLower(filepath.Ext(path)) {
	case ".flac":
		return readFLAC(file)
	case ".mp3":
		return readMP3(file)
	case ".m4a", ".alac":
		return readMP4(file)
	case ".aac":
		return readAAC(file)
	case ".ogg", ".opus":
		return readOgg(file)
	case ".wav":
		return readWAV(file)
	case ".aiff":
		return readAIFF(file)
	}
	return Meta{}, errUnsupportedFormat
}

// readAt reads exactly len(buf) bytes at offset, reporting io.EOF when the
// file is shorter.
func readAt(r io.ReaderAt, offset int64, buf []byte) error {
	_, err := r.ReadAt(buf, offset)
	return err
}

func readUint32BE(r io.ReaderAt, offset int64) (uint32, error) {
	var b [4]byte
	if err := readAt(r, offset, b[:]); err != nil {
		return 0, err
	}
	return binary.BigEndian.Uint32(b[:]), nil
}

func readUint64BE(r io.ReaderAt, offset int64) (uint64, error) {
	var b [8]byte
	if err := readAt(r, offset, b[:]); err != nil {
		return 0, err
	}
	return binary.BigEndian.Uint64(b[:]), nil
}

func readBytes(r io.ReaderAt, offset int64, size int64) ([]byte, error) {
	if size < 0 || size > maxTagBytes {
		return nil, fmt.Errorf("scan: tag region of %d bytes is out of range", size)
	}
	buf := make([]byte, size)
	if err := readAt(r, offset, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

// nonEmpty trims a value and returns "" for whitespace-only text, so tags
// that are present but blank do not mask the filename fallback.
func nonEmpty(value string) string {
	return strings.TrimSpace(value)
}

// parseYear takes the leading four digits of a date tag ("2020-05-01" → 2020).
func parseYear(value string) int {
	value = strings.TrimSpace(value)
	if len(value) < 4 {
		return 0
	}
	year := 0
	for i := 0; i < 4; i++ {
		c := value[i]
		if c < '0' || c > '9' {
			return 0
		}
		year = year*10 + int(c-'0')
	}
	return year
}

// parsePair reads "3/12" into (3, 12) or "07" into (7, 0).
func parsePair(value string) (int, int) {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0, 0
	}
	parts := strings.SplitN(value, "/", 2)
	return parsePositiveInt(parts[0]), optionalInt(parts)
}

func optionalInt(parts []string) int {
	if len(parts) < 2 {
		return 0
	}
	return parsePositiveInt(parts[1])
}

func parsePositiveInt(value string) int {
	value = strings.TrimSpace(value)
	n := 0
	for _, r := range value {
		if r < '0' || r > '9' {
			return 0
		}
		n = n*10 + int(r-'0')
		if n > 1<<20 {
			return 0
		}
	}
	return n
}

// durationFromFrames converts a frame count to a duration.
func durationFromFrames(frames uint64, samplesPerFrame int, sampleRate int) time.Duration {
	if sampleRate <= 0 || samplesPerFrame <= 0 {
		return 0
	}
	seconds := float64(frames) * float64(samplesPerFrame) / float64(sampleRate)
	return time.Duration(seconds * float64(time.Second))
}

// id3GenreNames is the ID3v1 genre list, used by ID3v1 tags and MP4 gnre.
var id3GenreNames = []string{
	"Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop",
	"Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock",
	"Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack",
	"Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance",
	"Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
	"AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop",
	"Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic",
	"Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
	"Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret",
	"New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal",
	"Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
}

func genreName(index int) string {
	if index >= 0 && index < len(id3GenreNames) {
		return id3GenreNames[index]
	}
	return ""
}

// factTrack builds the sparse result for a file whose tags need not be read
// because its size and modification time match what the library recorded.
func factTrack(path, format string, size int64, modified time.Time) library.ScannedTrack {
	return library.ScannedTrack{
		FilePathOrURL: path,
		Title:         strings.TrimSuffix(filepath.Base(path), filepath.Ext(path)),
		FileFormat:    format,
		FileSize:      size,
		LastModified:  modified,
	}
}
