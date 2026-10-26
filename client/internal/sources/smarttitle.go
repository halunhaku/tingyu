package sources

// SmartTitleParser, ported from app/lib/sources/scraper/smart_title_parser.dart.
// A remote source only has file names, so this is the input the metadata
// milestone will enrich. The "second part is the artist" special case is this
// library's naming habit (`歌手 - 歌名 - 专辑` and `歌名 - 周杰伦` mixed), not a
// general rule: the Dart implementation says so and the port keeps it.

import (
	"regexp"
	"strings"
)

// Placeholder metadata the library schema uses for unknowns.
const (
	UnknownArtist = "未知艺术家"
	UnknownAlbum  = "未知专辑"
	// WebDAVAlbum and QuarkAlbum are the placeholder albums the two sources
	// write when the file name carries none (webdav_client.dart and
	// quark_drive_client.dart).
	WebDAVAlbum = "WebDAV 曲库"
	QuarkAlbum  = "夸克曲库"
)

// ParsedSongInfo is what a file name could be split into.
type ParsedSongInfo struct {
	Title  string
	Artist string
	Album  string
}

var noisePatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)\s*\[(?:HQ|SQ|FLAC|Hi-Res|320k|128k|\d+kbps|无损|高品质|现场|Live|官方|伴奏|Remix).*?\]`),
	regexp.MustCompile(`(?i)\s*\((?:HQ|SQ|FLAC|Hi-Res|320k|128k|\d+kbps|无损|高品质|现场|Live|伴奏|Remix|韩语中字|live版).*?\)`),
	regexp.MustCompile(`(?i)[-_](?:320k|128k|flac|hq|sq)`),
}

var (
	leadingNumberPattern = regexp.MustCompile(`^\s*\d{1,3}\s*[-._\s]\s*`)
	edgePunctuation      = regexp.MustCompile(`^[.\s_-]+|[.\s_-]+$`)
	partSeparator        = regexp.MustCompile(`[-_|]`)
)

// audioExtensions are the extensions the parser strips before splitting. They
// mirror the Dart list (which is a subset check, not the scanner's set).
var audioExtensions = map[string]bool{
	"mp3": true, "flac": true, "m4a": true, "aac": true, "wav": true,
	"ogg": true, "opus": true, "aiff": true, "alac": true,
}

// ParseFilename parses `歌手 - 歌名 - 专辑`, `歌名 - 周杰伦`, `01. 歌名` and the
// rest of the same conventions.
func ParseFilename(filename string) ParsedSongInfo {
	clean := filename

	// 1. Drop the extension when the caller left it on.
	if dot := strings.LastIndex(clean, "."); dot > 0 && dot >= len(clean)-5 {
		if audioExtensions[strings.ToLower(clean[dot+1:])] {
			clean = clean[:dot]
		}
	}

	// 2. Drop a leading track number.
	clean = StripLeadingNumbers(clean)

	// 3. Split on the separators, cleaning each part.
	raw := partSeparator.Split(clean, -1)
	parts := make([]string, 0, len(raw))
	for _, part := range raw {
		cleaned := CleanPart(part)
		if cleaned != "" {
			parts = append(parts, cleaned)
		}
	}

	switch {
	case len(parts) >= 3:
		if looksLikeKnownArtist(parts[1]) {
			// 歌名 - 艺术家 - 专辑
			return ParsedSongInfo{Title: parts[0], Artist: parts[1], Album: parts[2]}
		}
		// 艺术家 - 歌名 - 专辑/版本
		return ParsedSongInfo{
			Title:  StripLeadingNumbers(parts[1]),
			Artist: StripLeadingNumbers(parts[0]),
			Album:  CleanPart(parts[2]),
		}
	case len(parts) == 2:
		if looksLikeKnownArtist(parts[1]) {
			// 歌名 - 艺术家
			return ParsedSongInfo{
				Title:  StripLeadingNumbers(parts[0]),
				Artist: StripLeadingNumbers(parts[1]),
				Album:  UnknownAlbum,
			}
		}
		// 艺术家 - 歌名
		return ParsedSongInfo{
			Title:  StripLeadingNumbers(parts[1]),
			Artist: StripLeadingNumbers(parts[0]),
			Album:  UnknownAlbum,
		}
	case len(parts) == 1:
		return ParsedSongInfo{Title: parts[0], Artist: UnknownArtist, Album: UnknownAlbum}
	}
	return ParsedSongInfo{Title: CleanPart(clean), Artist: UnknownArtist, Album: UnknownAlbum}
}

// looksLikeKnownArtist keeps only the Dart implementation's rule: 周杰伦 and
// the 周杰 prefix. General artist detection belongs to metadata enrichment.
func looksLikeKnownArtist(part string) bool {
	value := strings.TrimSpace(part)
	return value == "周杰伦" || value == "周杰倫" || strings.Contains(value, "周杰")
}

// CleanPart trims edge punctuation and strips bitrate/quality annotations.
func CleanPart(input string) string {
	value := trimPunctuation(input)
	for _, pattern := range noisePatterns {
		value = pattern.ReplaceAllString(value, "")
	}
	return trimPunctuation(value)
}

// StripLeadingNumbers removes `01. ` / `3 - ` / `12_` prefixes.
func StripLeadingNumbers(input string) string {
	return trimPunctuation(leadingNumberPattern.ReplaceAllString(input, ""))
}

func trimPunctuation(value string) string {
	return edgePunctuation.ReplaceAllString(value, "")
}
