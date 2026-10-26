package metadata

import (
	"context"
	"fmt"
	"net/url"
	"strings"
	"time"
)

// QQMusic is 中文曲库's primary source (qq_music_provider.dart): titles,
// artists, albums and covers, no key, no account. The cover is assembled from
// the album mid, which is why the candidate keeps it.
type QQMusic struct {
	HTTP *HTTP
	// Endpoint overrides the public search URL (tests point it at httptest).
	Endpoint string
}

// QQMusicSearchEndpoint is the public search endpoint.
const QQMusicSearchEndpoint = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"

func (q *QQMusic) endpoint() string {
	if strings.TrimSpace(q.Endpoint) != "" {
		return q.Endpoint
	}
	return QQMusicSearchEndpoint
}

// NewQQMusic builds the provider over an optional HTTP client.
func NewQQMusic(client *HTTP) *QQMusic { return &QQMusic{HTTP: client} }

// Name is the provider id stored in logs and results.
func (*QQMusic) Name() string { return "qqmusic" }

// Search queries the public search endpoint.
func (q *QQMusic) Search(ctx context.Context, query SearchQuery, limit int) ([]Candidate, error) {
	search := buildSearchQuery(query)
	if search == "" {
		return nil, nil
	}
	if limit <= 0 {
		limit = 1
	}
	http := q.HTTP
	if http == nil {
		http = &HTTP{}
	}
	body, err := http.getJSON(ctx, q.Name(), q.endpoint(), url.Values{
		"p":      {"1"},
		"n":      {fmt.Sprint(limit)},
		"w":      {search},
		"format": {"json"},
	}, map[string]string{"Referer": "https://y.qq.com"})
	if err != nil {
		return nil, err
	}
	list := listValue(mapValue(mapValue(body["data"])["song"])["list"])
	out := make([]Candidate, 0, len(list))
	for _, entry := range list {
		song := mapValue(entry)
		mid := stringValue(song["songmid"])
		title := stringValue(song["songname"])
		albumMid := stringValue(song["albummid"])
		album := stringValue(song["albumname"])
		if mid == "" || title == "" || albumMid == "" {
			continue
		}
		out = append(out, Candidate{
			Provider: "qqmusic",
			Title:    title,
			Artist:   firstSinger(song),
			Album:    album,
			CoverURL: CoverURLForAlbumMid(albumMid),
			SourceID: mid,
			Duration: time.Duration(numberValue(song["interval"]) * float64(time.Second)),
		})
	}
	return out, nil
}

// CoverURLForAlbumMid is the 800×800 gtimg template.
func CoverURLForAlbumMid(albumMid string) string {
	return "https://y.gtimg.cn/music/photo_new/T002R800x800M000" + albumMid + ".jpg"
}

func firstSinger(song map[string]any) string {
	for _, entry := range listValue(song["singer"]) {
		if name := stringValue(mapValue(entry)["name"]); name != "" {
			return name
		}
	}
	return ""
}
