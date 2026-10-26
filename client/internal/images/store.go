package images

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/halunhaku/tingyu/client/internal/scan"
)

// Store is the content-addressed cover directory. It wraps scan.SaveCover and
// scan.CollectOrphanCovers — the same code the local scanner and the M3 source
// deletion use — and adds the counters the M5 acceptance reports: how many
// remote covers were actually written, how many were already on disk, and how
// many orphans pruning removed.
type Store struct {
	Dir string

	mu     sync.Mutex
	saved  int64
	reused int64
	pruned int64
}

// StoreStats is a snapshot of the counters.
type StoreStats struct {
	Saved  int64 // files written by a remote fetch
	Reused int64 // fetches whose content was already on disk
	Pruned int64 // orphan files removed
}

// Stats returns the counters.
func (s *Store) Stats() StoreStats {
	s.mu.Lock()
	defer s.mu.Unlock()
	return StoreStats{Saved: s.saved, Reused: s.reused, Pruned: s.pruned}
}

// Save writes image bytes under their content name and reports whether the
// content was already present. The name is scan.CoverName's, so a cover that
// arrived embedded in a FLAC and later from iTunes shares one file.
func (s *Store) Save(data []byte) (string, bool, error) {
	if s == nil || s.Dir == "" {
		return "", false, fmt.Errorf("images: no cover directory")
	}
	if len(data) == 0 {
		return "", false, nil
	}
	name := scan.CoverName(data)
	existed := false
	if info, err := os.Stat(filepath.Join(s.Dir, name)); err == nil && info.Size() == int64(len(data)) {
		existed = true
	}
	if _, err := scan.SaveCover(s.Dir, data); err != nil {
		return "", existed, err
	}
	s.mu.Lock()
	if existed {
		s.reused++
	} else {
		s.saved++
	}
	s.mu.Unlock()
	return name, existed, nil
}

// Path resolves a cover name to an existing file.
func (s *Store) Path(name string) (string, bool) {
	if s == nil || s.Dir == "" || name == "" {
		return "", false
	}
	path := filepath.Join(s.Dir, name)
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return "", false
	}
	return path, true
}

// Prune removes every cover file no track references and counts them. keep is
// the set from library.ReferencedCovers: shared covers stay because the other
// track that uses them is still in the set.
func (s *Store) Prune(keep map[string]bool) (int, error) {
	if s == nil || s.Dir == "" {
		return 0, nil
	}
	removed, err := scan.CollectOrphanCovers(s.Dir, keep)
	if err != nil {
		return removed, err
	}
	s.mu.Lock()
	s.pruned += int64(removed)
	s.mu.Unlock()
	return removed, nil
}
