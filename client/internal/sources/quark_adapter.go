package sources

// Quark source: scan a folder tree into track facts and resolve `quark://<fid>`
// to a direct link plus playback headers. Ported from
// app/lib/sources/quark/quark_source_adapter.dart.
//
// Sessions are restored from the Keychain on every call; logging in does not
// rebuild the adapter, and a merged Set-Cookie is written back immediately, so
// a rotated `__puus` does not log the user out mid-scan.

import (
	"context"
	"fmt"
	"github.com/halunhaku/tingyu/client/internal/titleparse"
	"strings"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// QuarkSource is one configured Quark source.
type QuarkSource struct {
	sourceID  string
	folderFID string
	creds     *Credentials
	client    *QuarkClient
	maxDepth  int
	maxFiles  int
	logf      func(string, ...any)
}

// QuarkSourceOptions configure a Quark source adapter.
type QuarkSourceOptions struct {
	SourceID  string
	FolderFID string
	MaxDepth  int
	MaxFiles  int
	Logf      func(string, ...any)
}

// NewQuarkSource builds the adapter.
func NewQuarkSource(creds *Credentials, client *QuarkClient, options QuarkSourceOptions) *QuarkSource {
	if options.MaxDepth <= 0 {
		options.MaxDepth = QuarkMaxDepth
	}
	if options.MaxFiles <= 0 {
		options.MaxFiles = QuarkMaxFiles
	}
	return &QuarkSource{
		sourceID:  options.SourceID,
		folderFID: firstNonEmpty(options.FolderFID, "0"),
		creds:     creds,
		client:    client,
		maxDepth:  options.MaxDepth,
		maxFiles:  options.MaxFiles,
		logf:      options.Logf,
	}
}

// QuarkURIScheme prefixes a library path for a Quark file.
const QuarkURIScheme = "quark://"

// Kind is sources.KindQuark.
func (q *QuarkSource) Kind() string { return KindQuark }

// SourceID is the music_sources row.
func (q *QuarkSource) SourceID() string { return q.sourceID }

// FolderFID is the root folder id of the scan.
func (q *QuarkSource) FolderFID() string { return q.folderFID }

// FIDOf extracts the file id from a library path.
func FIDOf(filePathOrURL string) (string, error) {
	if !strings.HasPrefix(filePathOrURL, QuarkURIScheme) {
		return "", quarkParseError("无效的夸克文件地址: %s", filePathOrURL)
	}
	fid := strings.TrimSpace(strings.TrimPrefix(filePathOrURL, QuarkURIScheme))
	if fid == "" {
		return "", quarkParseError("无效的夸克文件地址: %s", filePathOrURL)
	}
	return fid, nil
}

// session restores the Cookie and wires the write-back hook.
func (q *QuarkSource) session() (*QuarkSession, error) {
	cookie, found, err := q.creds.QuarkCookie(q.sourceID)
	if err != nil {
		return nil, wrapError(KindOther, err, "读取夸克登录凭据失败")
	}
	if !found || cookie == "" {
		return nil, quarkAuthError(QuarkUnauthenticatedMessage)
	}
	jar := ParseQuarkCookie(cookie)
	if jar.IsEmpty() {
		return nil, quarkAuthError(QuarkUnauthenticatedMessage)
	}
	session := NewQuarkSession(jar)
	session.OnChange(func(updated string) {
		if writeErr := q.creds.SetQuarkCookie(q.sourceID, updated); writeErr != nil && q.logf != nil {
			// A failed write-back must not stop playback: the session still
			// works in memory, and the next launch simply needs a re-login.
			q.logf("sources: quark: persist rotated cookie: %v", writeErr)
		}
	})
	return session, nil
}

// CheckSession validates the stored Cookie, distinguishing expired from
// temporarily unavailable.
func (q *QuarkSource) CheckSession(ctx context.Context) (QuarkSessionCheck, error) {
	session, err := q.session()
	if err != nil {
		if IsAuth(err) {
			return QuarkSessionCheck{State: QuarkSessionExpired}, nil
		}
		return QuarkSessionCheck{}, err
	}
	return q.client.ValidateSession(ctx, session), nil
}

// Scan walks the drive breadth-first. A folder that could not be listed
// completely marks the result truncated, never "empty" (plan §2.1 #2).
func (q *QuarkSource) Scan(ctx context.Context, progress Progress) (ScanResult, error) {
	result := ScanResult{Tracks: make([]library.ScannedTrack, 0, 32)}
	session, err := q.session()
	if err != nil {
		return result, err
	}
	type folderJob struct {
		fid   string
		depth int
	}
	queue := []folderJob{{fid: q.folderFID, depth: 0}}
	visited := map[string]bool{}

	for len(queue) > 0 && len(result.Tracks) < q.maxFiles {
		if ctx.Err() != nil {
			result.Cancelled = true
			break
		}
		job := queue[0]
		queue = queue[1:]
		if !visited[job.fid] {
			visited[job.fid] = true
		} else {
			continue
		}
		listing, listErr := q.client.ListFolder(ctx, job.fid, session)
		if listErr != nil {
			if ctx.Err() != nil {
				result.Cancelled = true
				break
			}
			// A listing failure aborts the scan, as the Dart adapter does.
			return result, listErr
		}
		if !listing.Complete {
			result.Truncated = true
			if result.TruncationReason == "" {
				result.TruncationReason = listing.IncompleteReason
			}
		}
		for _, item := range listing.Items {
			if ctx.Err() != nil {
				result.Cancelled = true
				break
			}
			if item.IsFolder {
				if job.depth+1 > q.maxDepth {
					result.Truncated = true
					if result.TruncationReason == "" {
						result.TruncationReason = fmt.Sprintf("目录层级超过 %d 层", q.maxDepth)
					}
					continue
				}
				if !visited[item.ID] {
					queue = append(queue, folderJob{fid: item.ID, depth: job.depth + 1})
				}
				continue
			}
			dot := strings.LastIndex(item.Name, ".")
			if dot <= 0 {
				continue // no extension (including dot-files) is never audio
			}
			ext := strings.ToLower(item.Name[dot+1:])
			if !supportedExtension(item.Name) {
				continue
			}
			parsed := titleparse.ParseFilename(item.Name[:dot])
			album := parsed.Album
			if album == UnknownAlbum {
				album = QuarkAlbum
			}
			result.Tracks = append(result.Tracks, library.ScannedTrack{
				FilePathOrURL: QuarkURIScheme + item.ID,
				Title:         parsed.Title,
				Artist:        parsed.Artist,
				Album:         album,
				FileFormat:    ext,
				FileSize:      item.Size,
			})
			if progress != nil {
				progress(len(result.Tracks), parsed.Title)
			}
			if len(result.Tracks) >= q.maxFiles {
				result.Truncated = true
				if result.TruncationReason == "" {
					result.TruncationReason = fmt.Sprintf("达到 %d 首上限", q.maxFiles)
				}
				break
			}
		}
		if err := sleepContext(ctx, q.client.folderDelay); err != nil {
			result.Cancelled = true
			break
		}
	}
	return result, nil
}

// Open resolves a `quark://<fid>` path to a direct link and the headers the CDN
// requires. mpv fetches the bytes directly; Go never relays them.
func (q *QuarkSource) Open(ctx context.Context, filePathOrURL string) (Playable, error) {
	fid, err := FIDOf(filePathOrURL)
	if err != nil {
		return Playable{}, err
	}
	session, err := q.session()
	if err != nil {
		return Playable{}, err
	}
	link, err := q.client.GetDownloadURL(ctx, fid, session)
	if err != nil {
		return Playable{}, err
	}
	return Playable{URI: link, Headers: QuarkPlaybackHeaders(session)}, nil
}

// Refresh invalidates the cached direct link for a library path, so the next
// Open mints a new one. Playback failure recovery calls it.
func (q *QuarkSource) Refresh(filePathOrURL string) {
	fid, err := FIDOf(filePathOrURL)
	if err != nil {
		return
	}
	q.client.Invalidate(fid)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
