package scan

// Content-addressed cover files, byte-compatible with app/lib/data/cover_store.dart:
// FNV-1a 64 over the image bytes, 63 bits kept (no negative hex), padded to
// 16 characters, and ".png" only for the PNG signature (everything else .jpg).
// Naming by content is what keeps one album's embedded cover as one file
// instead of one per track (the audit found 91% duplicated bytes).

import (
	"fmt"
	"os"
	"path/filepath"
)

// CoverName returns the cache file name for image bytes.
func CoverName(data []byte) string {
	return fmt.Sprintf("%016x%s", fnv1a64(data)&0x7FFFFFFFFFFFFFFF, coverExt(data))
}

func fnv1a64(data []byte) uint64 {
	const (
		offset = 0xcbf29ce484222325
		prime  = 0x100000001b3
	)
	hash := uint64(offset)
	for _, b := range data {
		hash ^= uint64(b)
		hash *= prime
	}
	return hash
}

func coverExt(data []byte) string {
	if len(data) >= 8 && data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G' {
		return ".png"
	}
	return ".jpg"
}

// SaveCover writes data into coversDir under its content name, skipping the
// write when the same content is already there. Scans repeat, and rewriting
// hundreds of megabytes of identical bytes each time is waste, not work.
func SaveCover(coversDir string, data []byte) (string, error) {
	if len(data) == 0 {
		return "", nil
	}
	if err := os.MkdirAll(coversDir, 0o755); err != nil {
		return "", fmt.Errorf("scan: covers directory: %w", err)
	}
	name := CoverName(data)
	path := filepath.Join(coversDir, name)
	if info, err := os.Stat(path); err == nil && info.Size() == int64(len(data)) {
		return name, nil
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return "", fmt.Errorf("scan: write cover %s: %w", name, err)
	}
	return name, nil
}
