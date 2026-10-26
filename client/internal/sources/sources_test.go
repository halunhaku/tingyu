package sources

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo"

	"github.com/halunhaku/tingyu/client/internal/library"
)

func TestErrorKindsCarryTheFlutterSentences(t *testing.T) {
	if got := newError(KindAuth, "%s", WebDAVUnauthorized).Error(); got != WebDAVUnauthorized {
		t.Fatalf("auth sentence = %q", got)
	}
	if !IsAuth(newError(KindAuth, "%s", QuarkUnauthenticatedMessage)) {
		t.Fatal("IsAuth does not see a KindAuth error")
	}
	if IsAuth(newError(KindNetwork, "网络连接失败")) {
		t.Fatal("IsAuth is true for a network error")
	}
	wrapped := wrapError(KindNetwork, errors.New("connection refused"), "网络连接失败")
	if wrapped.Error() != "网络连接失败: connection refused" {
		t.Fatalf("wrapped = %q", wrapped.Error())
	}
	if KindOf(wrapped) != KindNetwork {
		t.Fatalf("kind = %v", KindOf(wrapped))
	}
	// The Nutstore body selects the blocked sentence, the documented branch.
	if got := webDAVRateLimited("<html>BlockedTemporarily</html>").Message; got != WebDAVBlocked {
		t.Fatalf("blocked sentence = %q", got)
	}
	if got := webDAVRateLimited("").Message; got != WebDAVFlowControl {
		t.Fatalf("flow-control sentence = %q", got)
	}
}

func TestRetryReplaysOnlyWhatIsWorthReplaying(t *testing.T) {
	retry := Retry{MaxAttempts: 3, BaseDelay: time.Millisecond, MaxDelay: 2 * time.Millisecond}
	attempts := 0
	err := retry.Do(context.Background(), nil, func(attempt int) (bool, error) {
		attempts++
		if attempt < 3 {
			return true, errors.New("temporary")
		}
		return false, nil
	})
	if err != nil || attempts != 3 {
		t.Fatalf("attempts = %d, err = %v", attempts, err)
	}

	attempts = 0
	err = retry.Do(context.Background(), nil, func(attempt int) (bool, error) {
		attempts++
		return true, errors.New("idempotency says no")
	})
	if err == nil || attempts != 3 {
		t.Fatalf("non-retryable fn: attempts = %d, err = %v", attempts, err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	attempts = 0
	if err := retry.Do(ctx, nil, func(int) (bool, error) { attempts++; return true, nil }); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled retry error = %v", err)
	}
	if attempts != 0 {
		t.Fatalf("cancelled retry still ran %d attempts", attempts)
	}
}

func TestRetryableStatus(t *testing.T) {
	for _, status := range []int{429, 503, 500, 502} {
		if !RetryableStatus(status) {
			t.Errorf("status %d should be retryable", status)
		}
	}
	for _, status := range []int{200, 401, 403, 404} {
		if RetryableStatus(status) {
			t.Errorf("status %d should not be retryable", status)
		}
	}
}

func TestParseScutilProxy(t *testing.T) {
	sample := `<dictionary> {
  ExceptionsList : <array> {
    0 : *.local
  }
  HTTPEnable : 1
  HTTPPort : 7890
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 7891
  HTTPSProxy : proxy.internal
  ProxyAutoConfigEnable : 0
  SOCKSEnable : 0
}`
	if got := parseScutilProxy(sample); got != "http://proxy.internal:7891" {
		t.Fatalf("proxy = %q, want the HTTPS one", got)
	}
	if got := parseScutilProxy("HTTPEnable : 0\nHTTPProxy : 127.0.0.1\nHTTPPort : 1\n"); got != "" {
		t.Fatalf("disabled proxy = %q", got)
	}
	if got := parseScutilProxy(""); got != "" {
		t.Fatalf("empty output = %q", got)
	}
}

func TestQuarkCookieJarParsesAndDeduplicates(t *testing.T) {
	jar := ParseQuarkCookie("Cookie: a=1; b=2; Path=/; a=3; empty=; Path=/x")
	if jar.Header() != "a=3; b=2" {
		t.Fatalf("header = %q", jar.Header())
	}
	// Set-Cookie merge adds, replaces and deletes, and reports changes.
	if !jar.MergeSetCookie([]string{"c=1; Path=/", "a=; Max-Age=0"}) {
		t.Fatal("merge reported no change")
	}
	if jar.Header() != "b=2; c=1" {
		t.Fatalf("header after merge = %q", jar.Header())
	}
	if jar.MergeSetCookie([]string{"b=2; Path=/"}) {
		t.Fatal("an unchanged cookie reported a change")
	}
	// An Expires in the past deletes; an unparsable one must not.
	jar.MergeSetCookie([]string{"c=2; Expires=Thu, 01 Jan 1970 00:00:00 GMT"})
	if jar.Has("c") {
		t.Fatalf("expired cookie still present: %q", jar.Header())
	}
	jar.MergeSetCookie([]string{"d=1; Expires=Mon, 14-Sep-2026 10:00:00 GMT"})
	if !jar.Has("d") {
		t.Fatalf("non-RFC Expires deleted a live cookie: %q", jar.Header())
	}
	if got := ParseQuarkCookie("").IsEmpty(); !got {
		t.Fatal("empty cookie parsed as non-empty")
	}
}

func TestSyncStatusUsesTheFlutterSentences(t *testing.T) {
	if got := SyncStatus(ScanResult{}, library.MergeResult{Added: 1, Updated: 2, Removed: 3}); got != "已同步（新增 1 / 更新 2 / 移除 3）" {
		t.Fatalf("authoritative status = %q", got)
	}
	cancelled := ScanResult{Cancelled: true}
	if got := SyncStatus(cancelled, library.MergeResult{}); got != "已取消（保留未扫描曲目；新增 0 / 更新 0）" {
		t.Fatalf("cancelled status = %q", got)
	}
	truncated := ScanResult{Truncated: true, TruncationReason: "目录层级超过 8 层"}
	if got := SyncStatus(truncated, library.MergeResult{}); got != "部分同步（目录层级超过 8 层；保留未扫描曲目；新增 0 / 更新 0）" {
		t.Fatalf("truncated status = %q", got)
	}
	skipped := ScanResult{Skipped: 2}
	if got := SyncStatus(skipped, library.MergeResult{}); got != "部分同步（跳过 2 项；保留未扫描曲目；新增 0 / 更新 0）" {
		t.Fatalf("skipped status = %q", got)
	}
}

func TestKeychainShardsLongSecrets(t *testing.T) {
	if testing.Short() {
		t.Skip("keychain test skipped in -short")
	}
	store := Keychain{Service: "com.halunhaku.tingyu.sources.test"}
	key := "quark_cookie_test-shard"
	value := []byte(strings.Repeat("cookie=value;", 500)) // ~6500 B, above mygo's 2560
	t.Cleanup(func() { _ = store.Delete(key) })
	if err := store.Set(key, value); err != nil {
		t.Skipf("keychain unavailable on this machine: %v", err)
	}
	got, found, err := store.Get(key)
	if err != nil || !found {
		t.Fatalf("Get: found=%v err=%v", found, err)
	}
	if string(got) != string(value) {
		t.Fatalf("sharded secret came back as %d bytes, want %d", len(got), len(value))
	}
	// The manifest is not the secret: the first shard must exist separately.
	module := mygo.Secrets.Service(store.Service)
	first, err := module.Get(shardKey(key, 0))
	if err != nil || len(first) == 0 {
		t.Fatalf("shard 0 missing: %v", err)
	}
	if len(first) > mygo.MaxSecretSize {
		t.Fatalf("shard is %d B, above mygo's limit", len(first))
	}
	// Shrinking must drop the old shards, not append them.
	if err := store.Set(key, []byte("short")); err != nil {
		t.Fatalf("shorten: %v", err)
	}
	got, found, err = store.Get(key)
	if err != nil || !found || string(got) != "short" {
		t.Fatalf("after shrink: got %q found=%v err=%v", got, found, err)
	}
	if _, err := module.Get(shardKey(key, 0)); !errors.Is(err, mygo.ErrSecretNotFound) {
		t.Fatalf("stale shard 0 survived: %v", err)
	}
}

func TestManagerResolvesLocalPathsUntouched(t *testing.T) {
	lib := newLibraryFixture(t)
	manager, err := NewManager(lib, NewCredentials(NewMemoryStore()), ManagerOptions{})
	if err != nil {
		t.Fatalf("manager: %v", err)
	}
	playable, err := manager.Resolve(context.Background(), library.Track{ID: "t1", SourceID: "src-1", FilePath: "/music/a.flac"})
	if err != nil {
		t.Fatalf("resolve local: %v", err)
	}
	if playable.URI != "/music/a.flac" || len(playable.Headers) != 0 {
		t.Fatalf("local playable = %+v", playable)
	}
}
