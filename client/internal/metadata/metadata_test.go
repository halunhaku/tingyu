package metadata

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// jsonServer answers every request with body and records the queries it saw.
func jsonServer(t *testing.T, body string) (*httptest.Server, *[]string) {
	t.Helper()
	seen := &[]string{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*seen = append(*seen, r.URL.RawQuery)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)
	return server, seen
}

func failingHTTP() *HTTP {
	return &HTTP{Client: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("network is unreachable")
	})}}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestQQMusicParsesThePublicShape(t *testing.T) {
	server, seen := jsonServer(t, `{"data":{"song":{"list":[
		{"songmid":"0039Mn","songname":"晴天","albummid":"002g","albumname":"叶惠美",
		 "interval":269,"singer":[{"name":"周杰伦"}]}]}}}`)
	provider := &QQMusic{HTTP: &HTTP{Client: server.Client()}, Endpoint: server.URL}
	hits, err := provider.Search(context.Background(), SearchQuery{Title: "晴天", Artist: "周杰伦"}, 1)
	if err != nil || len(hits) != 1 {
		t.Fatalf("hits=%d err=%v", len(hits), err)
	}
	hit := hits[0]
	if hit.Title != "晴天" || hit.Artist != "周杰伦" || hit.Album != "叶惠美" {
		t.Fatalf("hit %+v", hit)
	}
	if hit.CoverURL != "https://y.gtimg.cn/music/photo_new/T002R800x800M000002g.jpg" {
		t.Fatalf("cover url %q", hit.CoverURL)
	}
	if hit.Duration != 269*time.Second {
		t.Fatalf("duration %v", hit.Duration)
	}
	if len(*seen) != 1 || !strings.Contains((*seen)[0], "w=%E6%99%B4%E5%A4%A9") {
		t.Fatalf("query string %v", *seen)
	}
}

func TestNetEaseSearchAndLyricsConvertToSimplified(t *testing.T) {
	search, _ := jsonServer(t, `{"result":{"songs":[{"id":186016,"name":"晴天",
		"artists":[{"name":"周傑倫"}],"album":{"name":"葉惠美","picUrl":"http://p1.music.126.net/a.jpg"}}]}}`)
	lyrics, _ := jsonServer(t, `{"lrc":{"lyric":"[00:01.00]故事的小黃花\n[00:05.00]從出生那年就飄著"}}`)
	provider := &NetEase{HTTP: &HTTP{Client: search.Client()},
		SearchEndpoint: search.URL, LyricsEndpoint: lyrics.URL}
	hits, err := provider.Search(context.Background(), SearchQuery{Title: "晴天"}, 1)
	if err != nil || len(hits) != 1 {
		t.Fatalf("hits=%d err=%v", len(hits), err)
	}
	if hits[0].Artist != "周傑倫" || hits[0].SourceID != "186016" {
		t.Fatalf("hit %+v", hits[0])
	}
	if hits[0].CoverURL != "https://p1.music.126.net/a.jpg?param=800y800" {
		t.Fatalf("cover %q", hits[0].CoverURL)
	}
	text, err := provider.Lyrics(context.Background(), LyricsQuery{Title: "晴天"}, &hits[0])
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(text, "黃") || strings.Contains(text, "從") || !strings.Contains(text, "黄花") {
		t.Fatalf("lyrics were not converted: %q", text)
	}
}

func TestITunesLooksUpTheAlbumAndUpscalesArtwork(t *testing.T) {
	server, seen := jsonServer(t, `{"results":[{"artworkUrl100":"https://is1.mzstatic.com/a/100x100bb.jpg"}]}`)
	provider := &ITunes{HTTP: &HTTP{Client: server.Client()}, Endpoint: server.URL}
	url, err := provider.CoverURL(context.Background(), SearchQuery{Album: "叶惠美", Artist: "周杰伦"})
	if err != nil {
		t.Fatal(err)
	}
	if url != "https://is1.mzstatic.com/a/600x600bb.jpg" {
		t.Fatalf("cover %q", url)
	}
	if !strings.Contains((*seen)[0], "entity=album") || !strings.Contains((*seen)[0], "%E5%8F%B6%E6%83%A0%E7%BE%8E") {
		t.Fatalf("query %q", (*seen)[0])
	}
}

func TestLRCLIBPrefersSyncedLyricsAndSendsDuration(t *testing.T) {
	server, seen := jsonServer(t, `{"syncedLyrics":"[00:01.00]晴天","plainLyrics":"晴天"}`)
	provider := &LRCLIB{HTTP: &HTTP{Client: server.Client()}, Endpoint: server.URL}
	text, err := provider.Lyrics(context.Background(), LyricsQuery{Title: "晴天", Artist: "周杰伦", Duration: 269 * time.Second}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if text != "[00:01.00]晴天" {
		t.Fatalf("lyrics %q", text)
	}
	query := (*seen)[0]
	for _, want := range []string{"track_name=", "artist_name=", "duration=269"} {
		if !strings.Contains(query, want) {
			t.Errorf("query %q lacks %q", query, want)
		}
	}
	if strings.Contains(query, "album_name=") {
		t.Errorf("query %q carries a placeholder album", query)
	}
}

func TestParseDictionaryAndConversion(t *testing.T) {
	table := ParseDictionary("# comment\n周\t週\n傑\t杰\n\nbad line\n")
	if len(table) != 2 || table["傑"] != "杰" {
		t.Fatalf("table %v", table)
	}
	converter := &OpenCC{}
	if got := converter.ToSimplified("周傑倫的晴天"); got != "周杰伦的晴天" {
		t.Fatalf("converted %q", got)
	}
	if got := converter.ToSimplified("晴天"); got != "晴天" {
		t.Fatalf("simplified input changed to %q", got)
	}
}

func TestAISettingsParseAndMask(t *testing.T) {
	settings, err := ParseAISettings(`{"isEnabled":true,"preset":"kimi","baseUrl":"https://api.moonshot.cn/v1","model":"moonshot-v1-8k","apiKey":"test-1234"}`)
	if err != nil {
		t.Fatal(err)
	}
	if !settings.Ready() || settings.Preset != "kimi" {
		t.Fatalf("settings %+v", settings)
	}
	masked := settings.MaskKey()
	if masked != "****1234" {
		t.Fatalf("masked %q", masked)
	}
	if strings.Contains(masked, "test-") {
		t.Fatal("the mask leaks the key")
	}
	if _, err := ParseAISettings("{not json"); err == nil {
		t.Fatal("a corrupt blob must be reported")
	}
	if (AISettings{Enabled: true}).Ready() {
		t.Fatal("enabled without base URL must not be ready")
	}
}

func TestParseAIReplyStripsFencesAndProse(t *testing.T) {
	reply := "以下是结果：\n```json\n[{\"id\":\"1\",\"title\":\"园游会\",\"artist\":\"周杰伦\",\"album\":\"七里香\"}]\n```\n希望有帮助"
	out, err := ParseAIReply(reply)
	if err != nil {
		t.Fatal(err)
	}
	if out["1"].Title != "园游会" || out["1"].Album != "七里香" {
		t.Fatalf("out %+v", out)
	}
	if _, err := ParseAIReply("no json here"); err == nil {
		t.Fatal("garbage must fail")
	}
}

// testHTTP is the client the tests' httptest servers accept.
func testHTTP() *HTTP { return &HTTP{Client: &http.Client{Timeout: 5 * time.Second}} }

func TestEnrichFillsEveryFieldFromTheSources(t *testing.T) {
	qq, _ := jsonServer(t, `{"data":{"song":{"list":[{"songmid":"m","songname":"晴天",
		"albummid":"a","albumname":"叶惠美","interval":269,"singer":[{"name":"周杰伦"}]}]}}}`)
	lrclib, _ := jsonServer(t, `{"syncedLyrics":"[00:01.00]晴天"}`)
	enricher := &Enricher{
		Primary: &QQMusic{HTTP: testHTTP(), Endpoint: qq.URL},
		Lyrics:  &LRCLIB{HTTP: testHTTP(), Endpoint: lrclib.URL},
	}
	result, err := enricher.Enrich(context.Background(), Input{
		Title: "01. 晴天-周杰伦-叶惠美.flac", Artist: "未知艺术家", Album: "未知专辑",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !result.Changed || result.Offline {
		t.Fatalf("result %+v", result)
	}
	if result.Title != "晴天" || result.Artist != "周杰伦" || result.Album != "叶惠美" {
		t.Fatalf("metadata %+v", result)
	}
	if result.Lyrics != "[00:01.00]晴天" {
		t.Fatalf("lyrics %q", result.Lyrics)
	}
	if !strings.Contains(result.CoverURL, "gtimg") {
		t.Fatalf("cover %q", result.CoverURL)
	}
	if len(result.Sources) < 2 {
		t.Fatalf("sources %v", result.Sources)
	}
}

func TestEnrichFallsBackToNeteaseAndITunesForTheCover(t *testing.T) {
	neteaseSearch, _ := jsonServer(t, `{"result":{"songs":[{"id":1,"name":"晴天",
		"artists":[{"name":"周杰伦"}],"album":{"name":"叶惠美","picUrl":""}}]}}`)
	neteaseLyrics, _ := jsonServer(t, `{"lrc":{"lyric":"[00:01.00]晴天"}}`)
	itunes, _ := jsonServer(t, `{"results":[{"artworkUrl100":"https://is1.mzstatic.com/a/100x100bb.jpg"}]}`)
	fallback := &NetEase{HTTP: testHTTP(), SearchEndpoint: neteaseSearch.URL, LyricsEndpoint: neteaseLyrics.URL}
	enricher := &Enricher{
		Fallback:       fallback,
		FallbackLyrics: fallback,
		Cover:          &ITunes{HTTP: testHTTP(), Endpoint: itunes.URL},
	}
	result, err := enricher.Enrich(context.Background(), Input{
		Title: "晴天", Artist: "未知艺术家", Album: "未知专辑",
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Lyrics != "[00:01.00]晴天" {
		t.Fatalf("lyrics %q (want the Netease fallback)", result.Lyrics)
	}
	if !strings.Contains(result.CoverURL, "600x600bb") {
		t.Fatalf("cover %q (want the iTunes fallback)", result.CoverURL)
	}
}

func TestEnrichOfflineSkipsWithoutError(t *testing.T) {
	offline := failingHTTP()
	enricher := &Enricher{
		Primary:  &QQMusic{HTTP: offline, Endpoint: "https://example.invalid/x"},
		Fallback: &NetEase{HTTP: offline, SearchEndpoint: "https://example.invalid/y"},
		Lyrics:   &LRCLIB{HTTP: offline, Endpoint: "https://example.invalid/z"},
		Cover:    &ITunes{HTTP: offline, Endpoint: "https://example.invalid/w"},
	}
	result, err := enricher.Enrich(context.Background(), Input{Title: "晴天", Artist: "未知艺术家"})
	if err != nil {
		t.Fatalf("offline must not be an error: %v", err)
	}
	if !result.Offline {
		t.Fatalf("result %+v, want offline", result)
	}
	if result.CoverURL != "" || result.Lyrics != "" || result.Artist != "" && result.Artist != "周杰伦" {
		t.Fatalf("offline produced upstream data: %+v", result)
	}
}

func TestEnrichSkipsCompleteTracksWithoutAnyRequest(t *testing.T) {
	var requests int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		_, _ = w.Write([]byte(`{}`))
	}))
	defer server.Close()
	enricher := &Enricher{
		Primary: &QQMusic{HTTP: &HTTP{Client: server.Client()}, Endpoint: server.URL},
		Lyrics:  &LRCLIB{HTTP: &HTTP{Client: server.Client()}, Endpoint: server.URL},
	}
	result, err := enricher.Enrich(context.Background(), Input{
		Title: "晴天", Artist: "周杰伦", Album: "叶惠美", Lyrics: "[00:01.00]x", HasCover: true,
	})
	if err != nil || !result.Skipped || requests != 0 {
		t.Fatalf("result %+v requests=%d err=%v", result, requests, err)
	}
}

func TestEnrichRefusesTheSuspiciousTitle(t *testing.T) {
	enricher := &Enricher{}
	result, err := enricher.Enrich(context.Background(), Input{Title: "周杰伦", Artist: "未知艺术家"})
	if err != nil || !result.Skipped || result.Changed {
		t.Fatalf("result %+v err=%v", result, err)
	}
}

func TestEnrichUsesTheAIFallbackWhenSearchMisses(t *testing.T) {
	qq, _ := jsonServer(t, `{"data":{"song":{"list":[]}}}`)
	ai := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"[{\"id\":\"1\",\"title\":\"园游会\",\"artist\":\"周杰伦\",\"album\":\"七里香\"}]"}}]}`))
	}))
	defer ai.Close()
	client := NewAIClient(AISettings{Enabled: true, BaseURL: ai.URL, Model: "test", APIKey: "test-key"}, ai.Client())
	if client == nil {
		t.Fatal("AI client not built")
	}
	enricher := &Enricher{Primary: &QQMusic{HTTP: &HTTP{Client: qq.Client()}, Endpoint: qq.URL}}
	enricher.SetAI(client)
	result, err := enricher.Enrich(context.Background(), Input{Title: "01. y园游会-live.mp3", Artist: "未知艺术家"})
	if err != nil {
		t.Fatal(err)
	}
	if result.Title == "" || result.Title == "01. y园游会-live.mp3" {
		t.Fatalf("title %q", result.Title)
	}
	found := false
	for _, source := range result.Sources {
		if source == "ai" {
			found = true
		}
	}
	if !found {
		t.Fatalf("sources %v do not mention the AI fallback", result.Sources)
	}
}

func TestCandidatesMergeAndDeduplicate(t *testing.T) {
	qq, _ := jsonServer(t, `{"data":{"song":{"list":[
		{"songmid":"a","songname":"晴天","albummid":"1","albumname":"叶惠美","singer":[{"name":"周杰伦"}]},
		{"songmid":"b","songname":"晴天 (Live)","albummid":"2","albumname":"演唱会","singer":[{"name":"周杰伦"}]}]}}}`)
	netease, _ := jsonServer(t, `{"result":{"songs":[
		{"id":7,"name":"晴天","artists":[{"name":"周杰伦"}],"album":{"name":"叶惠美","picUrl":""}}]}}`)
	enricher := &Enricher{
		Primary:  &QQMusic{HTTP: &HTTP{Client: qq.Client()}, Endpoint: qq.URL},
		Fallback: &NetEase{HTTP: &HTTP{Client: netease.Client()}, SearchEndpoint: netease.URL},
	}
	hits, err := enricher.Candidates(context.Background(), SearchQuery{Title: "晴天"}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 2 {
		t.Fatalf("%d candidates, want 2 after deduplication: %+v", len(hits), hits)
	}
	if hits[0].Provider != "qqmusic" || hits[1].Provider != "qqmusic" {
		t.Fatalf("provider order %+v", hits)
	}
}

func TestUpstreamErrorClassification(t *testing.T) {
	network := &UpstreamError{Provider: "x", URL: "u", Network: true, Err: errors.New("down")}
	if !IsNetwork(network) {
		t.Fatal("network failure not classified")
	}
	status := &UpstreamError{Provider: "x", URL: "u", Status: 503}
	if IsNetwork(status) {
		t.Fatal("an HTTP status is not a network failure")
	}
	if !strings.Contains(status.Error(), "503") {
		t.Fatalf("message %q", status.Error())
	}
}

func TestBuildSearchQueryDropsPlaceholders(t *testing.T) {
	if got := buildSearchQuery(SearchQuery{Title: "晴天", Artist: UnknownArtist, Album: QuarkAlbum}); got != "晴天" {
		t.Fatalf("query %q", got)
	}
	if got := buildSearchQuery(SearchQuery{}); got != "" {
		t.Fatalf("empty query %q", got)
	}
}
