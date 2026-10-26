package metadata

import (
	"context"
	"net/url"
	"strings"
)

// ITunes is the last cover fallback (itunes_cover_provider.dart): the Search
// API's album entity, which hits international releases the Chinese sources
// miss. It needs no key.
type ITunes struct {
	HTTP *HTTP
	// Endpoint overrides the public search URL (tests).
	Endpoint string
}

// ITunesSearchEndpoint is the public Search API.
const ITunesSearchEndpoint = "https://itunes.apple.com/search"

func (i *ITunes) endpoint() string {
	if strings.TrimSpace(i.Endpoint) != "" {
		return i.Endpoint
	}
	return ITunesSearchEndpoint
}

// NewITunes builds the provider.
func NewITunes(client *HTTP) *ITunes { return &ITunes{HTTP: client} }

// Name is the provider id.
func (*ITunes) Name() string { return "itunes" }

// CoverURL searches by album (and artist when known) and returns the 600×600
// artwork URL.
func (i *ITunes) CoverURL(ctx context.Context, query SearchQuery) (string, error) {
	album := strings.TrimSpace(query.Album)
	if isPlaceholderAlbum(album) {
		// Without an album the track's title is the best term available; the
		// iTunes album entity still finds the release it belongs to.
		album = strings.TrimSpace(query.Title)
	}
	if album == "" {
		return "", nil
	}
	term := album
	if artist := strings.TrimSpace(query.Artist); !IsPlaceholderArtist(artist) {
		term = album + " " + artist
	}
	http := i.HTTP
	if http == nil {
		http = &HTTP{}
	}
	body, err := http.getJSON(ctx, i.Name(), i.endpoint(), url.Values{
		"term":   {term},
		"entity": {"album"},
		"limit":  {"1"},
	}, nil)
	if err != nil {
		return "", err
	}
	results := listValue(body["results"])
	if len(results) == 0 {
		return "", nil
	}
	return HighResolutionArtwork(stringValue(mapValue(results[0])["artworkUrl100"])), nil
}

// HighResolutionArtwork swaps iTunes' 100×100 size segment for 600×600.
func HighResolutionArtwork(url string) string {
	if url == "" {
		return ""
	}
	return strings.ReplaceAll(url, "100x100bb", "600x600bb")
}
