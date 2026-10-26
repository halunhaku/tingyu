package metadata

import (
	"context"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// LRCLIB is the primary lyrics source (lrclib_provider.dart): timed lyrics by
// title/artist/album/duration, no key, no account. It asks clients to send a
// recognisable User-Agent.
type LRCLIB struct {
	HTTP *HTTP
	// Endpoint overrides the public lookup URL (tests).
	Endpoint string
}

// LRCLIBEndpoint is the public get endpoint.
const LRCLIBEndpoint = "https://lrclib.net/api/get"

func (l *LRCLIB) endpoint() string {
	if strings.TrimSpace(l.Endpoint) != "" {
		return l.Endpoint
	}
	return LRCLIBEndpoint
}

// NewLRCLIB builds the provider.
func NewLRCLIB(client *HTTP) *LRCLIB { return &LRCLIB{HTTP: client} }

// Name is the provider id.
func (*LRCLIB) Name() string { return "lrclib" }

// Lyrics fetches a lyric document, preferring the synced LRC over plain text.
func (l *LRCLIB) Lyrics(ctx context.Context, query LyricsQuery, _ *Candidate) (string, error) {
	title := strings.TrimSpace(query.Title)
	if title == "" {
		return "", nil
	}
	params := url.Values{"track_name": {title}}
	if artist := strings.TrimSpace(query.Artist); artist != "" && !IsPlaceholderArtist(artist) {
		params.Set("artist_name", artist)
	}
	if album := strings.TrimSpace(query.Album); album != "" && !IsPlaceholderAlbum(album) {
		params.Set("album_name", album)
	}
	if query.Duration > 0 {
		params.Set("duration", strconv.Itoa(int(query.Duration/time.Second)))
	}
	http := l.HTTP
	if http == nil {
		http = &HTTP{}
	}
	body, err := http.getJSON(ctx, l.Name(), l.endpoint(), params, nil)
	if err != nil {
		return "", err
	}
	converter := &OpenCC{}
	if synced := stringValue(body["syncedLyrics"]); synced != "" {
		return converter.ToSimplified(synced), nil
	}
	if plain := stringValue(body["plainLyrics"]); plain != "" {
		return converter.ToSimplified(plain), nil
	}
	return "", nil
}
