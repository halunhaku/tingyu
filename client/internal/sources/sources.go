// Package sources is M3: the remote music sources (WebDAV and Quark Drive).
//
// It owns three things and nothing else:
//
//   - turning a source into track facts (Adapter.Scan) — scanning never writes
//     the library. Syncer (sync.go) is the only writer and it goes through
//     library.MergeScan, whose semantics (only an authoritative snapshot
//     deletes) it must preserve;
//   - turning one library path into a playable URI plus the per-track HTTP
//     headers the kernel hands to mpv (Adapter.Open) — Go never proxies audio
//     bytes (plan §3.5);
//   - the protocol clients and their user-visible error copy, ported from
//     app/lib/sources/{webdav,quark} so the two clients say the same thing.
//
// Credentials live in the macOS Keychain (creds.go); no plaintext fallback is
// kept (plan §2.1 #7).
package sources

import (
	"context"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/scan"
)

// Source kinds, matching music_sources.kind as the Flutter client writes it.
const (
	KindLocal  = "local"
	KindWebDAV = "webdav"
	KindQuark  = "quark"
)

// Scan limits. WebDAV keeps the Flutter client's defaults (8/5000); Quark
// keeps its own (5/5000) from quark_source_adapter.dart.
const (
	WebDAVMaxDepth = 8
	WebDAVMaxFiles = 5000
	QuarkMaxDepth  = 5
	QuarkMaxFiles  = 5000
)

// Progress reports a scan that cannot know its total in advance: WebDAV and
// Quark discover entries while enumerating, so done is "found so far" and
// there is no total to divide by (writing done/total would park the bar at
// 100 %, which is what source_sync.dart explains).
type Progress func(done int, name string)

// ScanResult is one source scan. The fields mirror SourceScanResult in
// app/lib/sources/source_adapter.dart.
type ScanResult struct {
	Tracks []library.ScannedTrack
	// Skipped counts entries that could not be read or understood. A scan with
	// skips is not authoritative: a transient permission error must never be
	// read as "these tracks were deleted" (plan §2.1 #2).
	Skipped int
	// Cancelled means the caller stopped the scan; Tracks holds what was found
	// before that.
	Cancelled bool
	// Truncated means the result does not cover the whole source (depth or
	// count limit, unparsable folder response).
	Truncated bool
	// TruncationReason is the sentence shown to the user.
	TruncationReason string
}

// Authoritative reports whether this snapshot may delete tracks missing from
// it. Same rule as scan.Result.Authoritative and the Flutter SourceScanResult.
func (r ScanResult) Authoritative() bool {
	return !r.Cancelled && !r.Truncated && r.Skipped == 0
}

// Playable is what the playback kernel needs for one track: the URI mpv opens
// and the headers it sends with every request. Remote credentials are headers,
// never URL userinfo (plan §3.4/§3.5).
type Playable struct {
	URI     string
	Headers map[string]string
}

// Adapter is one configured source. Implementations are safe for concurrent
// use: playback resolves tracks from the prefetch goroutine while a scan may be
// running.
type Adapter interface {
	Kind() string
	SourceID() string
	// Scan enumerates the source. ctx cancellation means "stop and return what
	// was found", not an error.
	Scan(ctx context.Context, progress Progress) (ScanResult, error)
	// Open resolves one library file_path_or_url. Credential failures return an
	// error for which IsAuth holds, so the UI can offer "重新登录".
	Open(ctx context.Context, filePathOrURL string) (Playable, error)
}

// readyTimeout bounds one metadata request; the plan's old client used a 15 s
// connect and a 60 s receive budget, which maps to these two contexts.
const (
	requestTimeout = 20 * time.Second
	webdavTimeout  = 60 * time.Second
)

// fileExtension returns the lowercase extension without the dot, or "" when
// there is none. Parity with webdav_client.dart's fileExtension.
func fileExtension(name string) string {
	for i := len(name) - 1; i >= 0; i-- {
		if name[i] == '.' {
			if i == 0 || i == len(name)-1 {
				return ""
			}
			return lower(name[i+1:])
		}
	}
	return ""
}

func lower(value string) string {
	out := []byte(value)
	for i, b := range out {
		if b >= 'A' && b <= 'Z' {
			out[i] = b + ('a' - 'A')
		}
	}
	return string(out)
}

// supportedExtension reports whether the scanner would accept this name. The
// set comes from scan.SupportedExtensions, so a source can never ingest a
// format the local scanner and the playback kernel do not handle.
func supportedExtension(name string) bool {
	return scan.SupportedExtensions[fileExtension(name)]
}
