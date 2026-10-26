package metadata

import (
	"context"
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/titleparse"
)

// suspiciousTitle aborts enrichment: an artist's name stored as the title
// would poison every query (metadata_enricher.dart's guard, kept because the
// remote sources do produce rows like this).
const suspiciousTitle = "周杰伦"

// Enricher is the pipeline of metadata_enricher.dart: title cleaning, primary
// search (QQ), lyrics (LRCLIB then Netease), cover (primary, Netease, iTunes),
// with the AI fallback cleaning file names no source resolves.
//
// Every source is optional. A nil searcher, lyric provider, cover lookup or AI
// client is skipped, which is how a partial configuration stays silent instead
// of erroring.
type Enricher struct {
	Primary        Searcher
	Fallback       Searcher
	Lyrics         LyricsProvider
	FallbackLyrics LyricsProvider
	Cover          CoverLookup
	AI             *AIClient
	Log            func(format string, args ...any)
}

// Input is what the library already knows about a track.
type Input struct {
	Title  string
	Artist string
	Album  string
	Lyrics string
	// HasCover means a cover file already exists, so no cover is fetched.
	HasCover bool
	Duration time.Duration
	// FillMissingDuration allows a search hit's duration to fill a zero
	// duration in the library (remote sources report none).
	FillMissingDuration bool
}

// Result is what should be written back. Empty strings and a zero duration mean
// "keep what the library has".
type Result struct {
	Title    string
	Artist   string
	Album    string
	Lyrics   string
	CoverURL string
	Duration time.Duration

	// Changed reports at least one field to write.
	Changed bool
	// Skipped reports nothing to do: complete metadata, a suspicious title, or
	// no source answered with anything better.
	Skipped bool
	// Offline reports that every failed request never reached its upstream, so
	// the caller shows "skipped" rather than an error (plan §6 M5).
	Offline bool
	// Sources lists the providers that contributed, for the log and the
	// acceptance record.
	Sources []string
}

// probe records upstream failures and classifies them.
type probe struct {
	log     func(format string, args ...any)
	network int
	other   int
}

func (p *probe) fail(err error) bool {
	if err == nil {
		return false
	}
	if IsNetwork(err) {
		p.network++
	} else {
		p.other++
	}
	if p.log != nil {
		p.log("metadata: %v", err)
	}
	return true
}

// Enrich runs the pipeline. It returns an error only for a programming
// mistake (a nil enricher); upstream failures come back as Skipped/Offline,
// because enrichment is best-effort and the caller must never show a dialog
// for a dead endpoint.
func (e *Enricher) Enrich(ctx context.Context, in Input) (Result, error) {
	result := Result{}
	if e == nil {
		return result, nil
	}
	p := &probe{log: e.Log}

	parsed := titleparse.ParseFilename(in.Title)
	queryTitle := strings.TrimSpace(parsed.Title)
	artist := strings.TrimSpace(in.Artist)
	if IsPlaceholderArtist(artist) {
		artist = parsed.Artist
	}
	album := strings.TrimSpace(in.Album)
	if IsPlaceholderAlbum(album) {
		album = parsed.Album
	}
	if queryTitle == "" || queryTitle == artist || queryTitle == suspiciousTitle {
		result.Skipped = true
		return result, nil
	}

	// A file name that still looks like one gets the cleaned form written back
	// even when no source is queried.
	title := ""
	if looksMessy(in.Title) {
		title = queryTitle
	}
	if artist != in.Artist && !IsPlaceholderArtist(artist) {
		result.Artist = artist
	}
	if album != in.Album && !IsPlaceholderAlbum(album) {
		result.Album = album
	}
	if title != "" {
		result.Title = title
	}

	needsDuration := in.FillMissingDuration && in.Duration <= 0
	needsSearch := !in.HasCover || needsDuration || IsPlaceholderArtist(in.Artist) || IsPlaceholderAlbum(in.Album)
	if !needsSearch && in.HasCover && strings.TrimSpace(in.Lyrics) != "" {
		result.Changed = result.Title != "" || result.Artist != "" || result.Album != ""
		result.Skipped = !result.Changed
		return result, nil
	}

	query := SearchQuery{Title: queryTitle, Artist: artist, Album: album}
	var candidate *Candidate
	var apply func(Candidate)
	apply = func(hit Candidate) {
		if hit.Artist != "" {
			result.Artist = hit.Artist
		}
		if hit.Album != "" {
			result.Album = hit.Album
		}
		if in.HasCover {
			return
		}
		if hit.CoverURL != "" {
			result.CoverURL = hit.CoverURL
		}
	}

	if needsSearch && e.Primary != nil {
		hits, err := e.Primary.Search(ctx, query, 1)
		p.fail(err)
		if len(hits) > 0 && hits[0].MatchesTitle(queryTitle) {
			candidate = &hits[0]
			apply(*candidate)
			result.Sources = append(result.Sources, e.Primary.Name())
		}
	}

	// AI fallback: primary search found nothing matching, so let the model
	// repair the file name and retry the search once with its answer.
	if candidate == nil && e.AI != nil && (looksMessy(in.Title) || IsPlaceholderArtist(in.Artist)) {
		cleaned, aiErr := e.AI.CleanFilenames(ctx, []AIInput{{ID: "1", Filename: in.Title}})
		if !p.fail(aiErr) {
			if hit, ok := cleaned["1"]; ok && hit.Title != "" {
				result.Title = hit.Title
				if hit.Artist != "" {
					result.Artist = hit.Artist
					artist = hit.Artist
				}
				if hit.Album != "" {
					result.Album = hit.Album
					album = hit.Album
				}
				queryTitle = hit.Title
				result.Sources = append(result.Sources, "ai")
				query = SearchQuery{Title: queryTitle, Artist: artist, Album: album}
				if e.Primary != nil {
					hits, err := e.Primary.Search(ctx, query, 1)
					p.fail(err)
					if len(hits) > 0 && hits[0].MatchesTitle(queryTitle) {
						candidate = &hits[0]
						apply(*candidate)
						result.Sources = append(result.Sources, e.Primary.Name())
					}
				}
			}
		}
	}

	// Lyrics: LRCLIB first, Netease as the fallback (which needs its own
	// candidate id, so a Netease search may run here or be reused by the cover
	// step below).
	var fallbackCandidate *Candidate
	needFallbackSearch := func() *Candidate {
		if fallbackCandidate != nil || e.Fallback == nil {
			return fallbackCandidate
		}
		hits, err := e.Fallback.Search(ctx, query, 1)
		p.fail(err)
		if len(hits) > 0 && hits[0].MatchesTitle(queryTitle) {
			fallbackCandidate = &hits[0]
		}
		return fallbackCandidate
	}
	if strings.TrimSpace(in.Lyrics) == "" {
		lyricsQuery := LyricsQuery{Title: queryTitle, Artist: artist, Album: album, Duration: in.Duration}
		lyrics := ""
		if e.Lyrics != nil {
			text, err := e.Lyrics.Lyrics(ctx, lyricsQuery, nil)
			p.fail(err)
			if text != "" {
				lyrics = text
				result.Sources = append(result.Sources, e.Lyrics.Name())
			}
		}
		if lyrics == "" && e.FallbackLyrics != nil {
			if hit := needFallbackSearch(); hit != nil {
				text, err := e.FallbackLyrics.Lyrics(ctx, lyricsQuery, hit)
				p.fail(err)
				if text != "" {
					lyrics = text
					result.Sources = append(result.Sources, e.FallbackLyrics.Name())
				}
			}
		}
		result.Lyrics = lyrics
	}

	// Cover fallbacks: Netease, then iTunes.
	if !in.HasCover && result.CoverURL == "" && e.Fallback != nil {
		if hit := needFallbackSearch(); hit != nil && hit.CoverURL != "" {
			result.CoverURL = hit.CoverURL
			result.Sources = append(result.Sources, e.Fallback.Name())
		}
	}
	if !in.HasCover && result.CoverURL == "" && e.Cover != nil {
		url, err := e.Cover.CoverURL(ctx, SearchQuery{Title: queryTitle, Artist: artist, Album: album})
		p.fail(err)
		if url != "" {
			result.CoverURL = url
			result.Sources = append(result.Sources, e.Cover.Name())
		}
	}

	if needsDuration && candidate != nil && candidate.Duration > 0 {
		result.Duration = candidate.Duration
	}
	if result.Duration > 0 && result.Sources == nil {
		result.Sources = append(result.Sources, "duration")
	}

	result.Changed = result.Title != "" || result.Artist != "" || result.Album != "" ||
		result.Lyrics != "" || result.CoverURL != "" || result.Duration > 0
	if !result.Changed {
		result.Skipped = true
		// Every attempt failed without reaching the network: the caller says
		// "offline, skipped" and shows no error.
		result.Offline = p.network > 0 && p.other == 0
	}
	return result, nil
}

// Candidates lists search hits for the manual-match dialog: both search
// sources, deduplicated by title/artist/album, in provider order.
func (e *Enricher) Candidates(ctx context.Context, query SearchQuery, limit int) ([]Candidate, error) {
	if e == nil {
		return nil, nil
	}
	if limit <= 0 {
		limit = 10
	}
	seen := map[string]bool{}
	out := make([]Candidate, 0, limit)
	for _, searcher := range []Searcher{e.Primary, e.Fallback} {
		if searcher == nil {
			continue
		}
		hits, err := searcher.Search(ctx, query, limit)
		if err != nil {
			if IsNetwork(err) {
				return out, err
			}
			continue
		}
		for _, hit := range hits {
			key := strings.ToLower(hit.Title + "\x00" + hit.Artist + "\x00" + hit.Album)
			if seen[key] {
				continue
			}
			seen[key] = true
			out = append(out, hit)
			if len(out) >= limit {
				return out, nil
			}
		}
	}
	return out, nil
}

// looksMessy reports a title that is still a file name: an audio extension, a
// separator, or a dot (metadata_enricher.dart's _looksMessy).
func looksMessy(title string) bool {
	lower := strings.ToLower(strings.TrimSpace(title))
	for _, suffix := range []string{".mp3", ".flac", ".m4a"} {
		if strings.HasSuffix(lower, suffix) {
			return true
		}
	}
	return strings.ContainsAny(title, "-_.")
}
