package images

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// ErrFetch is the umbrella for a cover that could not be downloaded. Callers
// treat it as "no cover", never as a user-visible error: enrichment is
// best-effort by contract (plan §6 M5: offline skips silently).
var ErrFetch = errors.New("images: cover fetch failed")

// DefaultUserAgent is the UA the metadata endpoints expect (LRCLIB asks for a
// recognisable one; the CDNs do not care).
const DefaultUserAgent = "Tingyu/1.0 (https://github.com/halunhaku/tingyu)"

// maxCoverBytes bounds one cover download. A 600×600 JPEG is well under 1 MB;
// anything past this is an error page or a full-size artwork we do not want.
const maxCoverBytes = 24 << 20

// failureTTL is how long a failed URL is remembered, so a broken CDN link is
// not retried for every track of the album (the research report's artCache
// caches failures too).
const failureTTL = 5 * time.Minute

// FetchStats are the cover-cache counters the acceptance reports: requests,
// how many bytes were downloaded, how many were already on disk (cache hits),
// and how many failed.
type FetchStats struct {
	Requests   int64
	Downloaded int64
	Reused     int64
	Failed     int64
	Bytes      int64
}

// HitRate is the share of cover requests answered from disk.
func (s FetchStats) HitRate() float64 {
	total := s.Downloaded + s.Reused
	if total == 0 {
		return 0
	}
	return float64(s.Reused) / float64(total)
}

// Fetcher downloads remote covers into a Store. Concurrent requests for the
// same URL share one download, and a URL that just failed is not retried for
// failureTTL.
type Fetcher struct {
	Client    *http.Client
	Store     *Store
	UserAgent string
	Log       func(format string, args ...any)

	mu       sync.Mutex
	inflight map[string]*coverCall
	hits     map[string]string // URL → cover name already on disk
	failed   map[string]time.Time
	stats    FetchStats
	now      func() time.Time
}

type coverCall struct {
	done chan struct{}
	name string
	data []byte
	err  error
}

// Cover returns the cache file name and bytes of a remote cover, downloading
// it once. An empty URL is not an error; it is "no cover".
func (f *Fetcher) Cover(ctx context.Context, url string) (string, []byte, error) {
	url = strings.TrimSpace(url)
	if url == "" {
		return "", nil, nil
	}
	if f == nil || f.Store == nil {
		return "", nil, fmt.Errorf("images: fetcher has no store")
	}
	now := time.Now
	if f.now != nil {
		now = f.now
	}
	f.mu.Lock()
	if at, failed := f.failed[url]; failed && now().Sub(at) < failureTTL {
		f.mu.Unlock()
		return "", nil, fmt.Errorf("%w: %s (recently failed)", ErrFetch, url)
	}
	if name, known := f.hits[url]; known {
		if path, ok := f.Store.Path(name); ok {
			if data, readErr := os.ReadFile(path); readErr == nil {
				f.stats.Reused++
				f.mu.Unlock()
				return name, data, nil
			}
		}
		delete(f.hits, url)
	}
	if call, running := f.inflight[url]; running {
		f.mu.Unlock()
		select {
		case <-call.done:
			return call.name, call.data, call.err
		case <-ctx.Done():
			return "", nil, ctx.Err()
		}
	}
	call := &coverCall{done: make(chan struct{})}
	if f.inflight == nil {
		f.inflight = map[string]*coverCall{}
	}
	f.inflight[url] = call
	f.stats.Requests++
	f.mu.Unlock()

	name, data, err := f.download(ctx, url)

	f.mu.Lock()
	delete(f.inflight, url)
	if err != nil {
		if f.failed == nil {
			f.failed = map[string]time.Time{}
		}
		f.failed[url] = now()
		f.stats.Failed++
	} else if name != "" {
		if f.hits == nil {
			f.hits = map[string]string{}
		}
		f.hits[url] = name
	}
	f.mu.Unlock()
	call.name, call.data, call.err = name, data, err
	close(call.done)
	return name, data, err
}

func (f *Fetcher) download(ctx context.Context, url string) (string, []byte, error) {
	client := f.Client
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second}
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", nil, fmt.Errorf("%w: %s: %v", ErrFetch, url, err)
	}
	agent := f.UserAgent
	if agent == "" {
		agent = DefaultUserAgent
	}
	request.Header.Set("User-Agent", agent)
	request.Header.Set("Accept", "image/*")
	response, err := client.Do(request)
	if err != nil {
		return "", nil, fmt.Errorf("%w: %s: %v", ErrFetch, url, err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", nil, fmt.Errorf("%w: %s: HTTP %d", ErrFetch, url, response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxCoverBytes+1))
	if err != nil {
		return "", nil, fmt.Errorf("%w: %s: %v", ErrFetch, url, err)
	}
	if len(body) == 0 {
		return "", nil, fmt.Errorf("%w: %s: empty body", ErrFetch, url)
	}
	if len(body) > maxCoverBytes {
		return "", nil, fmt.Errorf("%w: %s: larger than %d bytes", ErrFetch, url, maxCoverBytes)
	}
	if _, err := Decode(body); err != nil {
		return "", nil, fmt.Errorf("%w: %s: %v", ErrFetch, url, err)
	}
	name, existed, err := f.Store.Save(body)
	if err != nil {
		return "", nil, err
	}
	f.mu.Lock()
	if existed {
		f.stats.Reused++
	} else {
		f.stats.Downloaded++
		f.stats.Bytes += int64(len(body))
	}
	f.mu.Unlock()
	if f.Log != nil {
		state := "downloaded"
		if existed {
			state = "merged"
		}
		f.Log("cover: %s %s (%d bytes, %s)", state, name, len(body), url)
	}
	return name, body, nil
}

// Stats returns the fetch counters.
func (f *Fetcher) Stats() FetchStats {
	if f == nil {
		return FetchStats{}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.stats
}
