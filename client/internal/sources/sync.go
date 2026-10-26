package sources

// Sync orchestration: scan → merge → update the source row, with the semantics
// plan §2.1 #2 fixes and source_sync.dart implements:
//
//   - only an authoritative snapshot (complete, not cancelled, nothing skipped)
//     may delete tracks missing from it;
//   - a cancelled or truncated scan keeps every unscanned track and still
//     writes the tracks it did find;
//   - a credential failure marks the source for re-login instead of silently
//     emptying it, and the message lands in sync_status;
//   - the scan is cancellable at any point.
//
// The merge itself is library.MergeScan, called with the existing API and
// without touching its semantics (the data-layer todo owns that file).

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// SyncOutcome is what one sync produced, for the UI and the acceptance log.
type SyncOutcome struct {
	Scan  ScanResult
	Merge library.MergeResult
	// Count is the real row count of the source after the merge.
	Count int64
	// Status is the sentence stored in music_sources.sync_status and shown on
	// the source card. It is the Flutter client's wording.
	Status string
	// NeedLogin means the credential is missing, wrong or expired: the UI must
	// offer "重新登录", not an empty library.
	NeedLogin bool
	// Message is the failure sentence for logs; empty on success.
	Message string
}

// Syncer runs one source sync at a time per source (the caller serializes).
type Syncer struct {
	Lib     *library.Library
	Manager *Manager
	Logf    func(string, ...any)
}

// Sync scans source and merges the facts into the library. An error means the
// merge did not happen (or the scan failed outright); outcome is still filled
// so the caller can show the reason and the re-login flag.
func (s *Syncer) Sync(ctx context.Context, source library.Source, progress Progress) (SyncOutcome, error) {
	var outcome SyncOutcome
	if s.Lib == nil || s.Manager == nil {
		err := newError(KindOther, "来源同步未初始化")
		outcome.Message = err.Error()
		return outcome, err
	}
	adapter, err := s.Manager.Adapter(ctx, source)
	if err != nil {
		s.recordFailure(ctx, source.ID, err)
		outcome.Message = err.Error()
		outcome.NeedLogin = IsAuth(err)
		return outcome, err
	}

	result, scanErr := adapter.Scan(ctx, progress)
	if scanErr != nil {
		// Cancellation is not a failure: ReportPartial must still write what was
		// found (the Adapter contract says so), but a transport error that
		// happens to arrive with a cancelled context is the cancellation.
		if ctx.Err() != nil || errors.Is(scanErr, context.Canceled) {
			result.Cancelled = true
			scanErr = nil
		}
	}
	if scanErr != nil {
		s.recordFailure(ctx, source.ID, scanErr)
		outcome.Message = scanErr.Error()
		outcome.NeedLogin = IsAuth(scanErr)
		if s.Logf != nil {
			s.Logf("sources: sync %s failed: %v", source.Name, scanErr)
		}
		return outcome, scanErr
	}

	// The write phase is local SQLite work and must finish even when the user
	// cancelled the scan: the cancellation stops enumeration, not the merge of
	// what was already found (and the snapshot is non-authoritative, so nothing
	// is deleted). A detached, bounded context is what makes the count in the
	// "已取消" status trustworthy.
	writeCtx, stopWrites := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer stopWrites()
	merge, mergeErr := s.Lib.MergeScan(writeCtx, source.ID, result.Tracks, result.Authoritative())
	if mergeErr != nil {
		s.recordFailure(ctx, source.ID, mergeErr)
		outcome.Message = mergeErr.Error()
		if s.Logf != nil {
			s.Logf("sources: merge %s failed: %v", source.Name, mergeErr)
		}
		return outcome, mergeErr
	}
	count, countErr := s.Lib.CountSourceTracks(writeCtx, source.ID)
	if countErr != nil {
		s.recordFailure(ctx, source.ID, countErr)
		outcome.Message = countErr.Error()
		return outcome, countErr
	}
	status := SyncStatus(result, merge)
	outcome.Scan = result
	outcome.Merge = merge
	outcome.Count = count
	outcome.Status = status
	if err := s.Lib.UpdateSourceSync(writeCtx, source.ID, status, time.Now().UTC(), count); err != nil && s.Logf != nil {
		// The tracks are in; a failed status write is cosmetic.
		s.Logf("sources: update sync status %s: %v", source.Name, err)
	}
	if s.Logf != nil {
		s.Logf("sources: sync %s done: scanned=%d skipped=%d cancelled=%v truncated=%v added=%d updated=%d removed=%d stored=%d",
			source.Name, len(result.Tracks), result.Skipped, result.Cancelled, result.Truncated,
			merge.Added, merge.Updated, merge.Removed, count)
	}
	return outcome, nil
}

// recordFailure stores the failure sentence on the source row, the way
// source_sync.dart does, so the card still explains itself after a restart. It
// keeps the previous last_synced_at and track count: a failed sync is not a
// sync, and claiming one would hide the failure.
func (s *Syncer) recordFailure(ctx context.Context, sourceID string, err error) {
	if s.Lib == nil || !s.Lib.Writable() {
		return
	}
	message := err.Error()
	if message == "" {
		message = "同步失败"
	}
	sources, readErr := s.Lib.Sources(ctx)
	if readErr != nil {
		if s.Logf != nil {
			s.Logf("sources: record failure for %s: %v", sourceID, readErr)
		}
		return
	}
	for _, source := range sources {
		if source.ID != sourceID {
			continue
		}
		source.SyncStatus = message
		if updateErr := s.Lib.UpsertSource(ctx, source); updateErr != nil && s.Logf != nil {
			s.Logf("sources: record failure for %s: %v", sourceID, updateErr)
		}
		return
	}
}

// SyncStatus is the user-visible outcome sentence, byte-identical to
// source_sync.dart's _syncStatus. It is also what the acceptance quotes.
func SyncStatus(result ScanResult, merge library.MergeResult) string {
	if result.Authoritative() {
		return fmt.Sprintf("已同步（新增 %d / 更新 %d / 移除 %d）",
			merge.Added, merge.Updated, merge.Removed)
	}
	if result.Cancelled {
		return fmt.Sprintf("已取消（保留未扫描曲目；新增 %d / 更新 %d）",
			merge.Added, merge.Updated)
	}
	if result.Truncated {
		reason := result.TruncationReason
		if reason == "" {
			reason = "来源内容未枚举完"
		}
		return fmt.Sprintf("部分同步（%s；保留未扫描曲目；新增 %d / 更新 %d）",
			reason, merge.Added, merge.Updated)
	}
	return fmt.Sprintf("部分同步（跳过 %d 项；保留未扫描曲目；新增 %d / 更新 %d）",
		result.Skipped, merge.Added, merge.Updated)
}
