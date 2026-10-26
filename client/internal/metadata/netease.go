package metadata

import (
	"context"
	"net/url"
	"strconv"
	"strings"
)

// NetEase is the lyrics and cover fallback (netease_provider.dart). It needs
// no account for search or lyrics; the browser headers are what the public
// endpoint expects.
type NetEase struct {
	HTTP *HTTP
	// SearchEndpoint / LyricsEndpoint override the public URLs (tests).
	SearchEndpoint string
	LyricsEndpoint string
}

// NetEase public endpoints.
const (
	NetEaseSearchEndpoint = "https://music.163.com/api/search/get/web"
	NetEaseLyricsEndpoint = "https://music.163.com/api/song/lyric"
)

func (n *NetEase) searchEndpoint() string {
	if strings.TrimSpace(n.SearchEndpoint) != "" {
		return n.SearchEndpoint
	}
	return NetEaseSearchEndpoint
}

func (n *NetEase) lyricsEndpoint() string {
	if strings.TrimSpace(n.LyricsEndpoint) != "" {
		return n.LyricsEndpoint
	}
	return NetEaseLyricsEndpoint
}

// NewNetEase builds the provider.
func NewNetEase(client *HTTP) *NetEase { return &NetEase{HTTP: client} }

var neteaseHeaders = map[string]string{
	"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
	"Referer":    "https://music.163.com",
}

// Name is the provider id.
func (*NetEase) Name() string { return "netease" }

// Search finds candidates. Songs whose album has no picture are still
// candidates (their lyrics may be what we want).
func (n *NetEase) Search(ctx context.Context, query SearchQuery, limit int) ([]Candidate, error) {
	search := buildSearchQuery(query)
	if search == "" {
		return nil, nil
	}
	if limit <= 0 {
		limit = 1
	}
	http := n.HTTP
	if http == nil {
		http = &HTTP{}
	}
	body, err := http.getJSON(ctx, n.Name(), n.searchEndpoint(), url.Values{
		"csrf_token": {""},
		"s":          {search},
		"type":       {"1"},
		"offset":     {"0"},
		"total":      {"true"},
		"limit":      {strconv.Itoa(limit)},
	}, neteaseHeaders)
	if err != nil {
		return nil, err
	}
	songs := listValue(mapValue(body["result"])["songs"])
	out := make([]Candidate, 0, len(songs))
	for _, entry := range songs {
		song := mapValue(entry)
		id := numberValue(song["id"])
		title := stringValue(song["name"])
		if id == 0 || title == "" {
			continue
		}
		album := mapValue(song["album"])
		out = append(out, Candidate{
			Provider: "netease",
			Title:    title,
			Artist:   firstNeteaseArtist(song),
			Album:    stringValue(album["name"]),
			CoverURL: normalizeCoverURL(stringValue(album["picUrl"])),
			SourceID: strconv.FormatInt(int64(id), 10),
		})
	}
	return out, nil
}

// Lyrics fetches the LRC of the candidate's song id and converts it to
// simplified Chinese. Without a candidate id there is nothing to fetch.
func (n *NetEase) Lyrics(ctx context.Context, query LyricsQuery, candidate *Candidate) (string, error) {
	id := ""
	if candidate != nil {
		id = candidate.SourceID
	}
	if id == "" {
		return "", nil
	}
	http := n.HTTP
	if http == nil {
		http = &HTTP{}
	}
	body, err := http.getJSON(ctx, n.Name(), n.lyricsEndpoint(), url.Values{
		"os": {"pc"},
		"id": {id},
		"lv": {"-1"},
		"kv": {"-1"},
		"tv": {"-1"},
	}, neteaseHeaders)
	if err != nil {
		return "", err
	}
	lyric := strings.TrimSpace(stringValue(mapValue(body["lrc"])["lyric"]))
	if lyric == "" {
		return "", nil
	}
	converter := &OpenCC{}
	return converter.ToSimplified(lyric), nil
}

func firstNeteaseArtist(song map[string]any) string {
	for _, entry := range listValue(song["artists"]) {
		if name := stringValue(mapValue(entry)["name"]); name != "" {
			return name
		}
	}
	return ""
}

// normalizeCoverURL upgrades http to https and asks the CDN for 800×800.
func normalizeCoverURL(raw string) string {
	clean := strings.TrimSpace(raw)
	if clean == "" {
		return ""
	}
	clean = strings.Replace(clean, "http://", "https://", 1)
	if strings.Contains(clean, "?") {
		return clean + "&param=800y800"
	}
	return clean + "?param=800y800"
}
