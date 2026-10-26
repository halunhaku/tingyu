package sources

// Fixtures shared by the source tests: a throwaway library in the production
// schema, and a scanned source row.

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/egoist/mygo/plugins/sqlite"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// newLibraryFixture creates a library.sqlite shaped like the production one
// (user_version 2, schema created by library's 补差 migration) in a temp dir.
// Tests never touch the real library.
func newLibraryFixture(t *testing.T) *library.Library {
	t.Helper()
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "library.sqlite")
	db, err := sqlite.Open(ctx, path, sqlite.OpenOptions{})
	if err != nil {
		t.Fatalf("create fixture: %v", err)
	}
	if _, err := db.Execute(ctx, "PRAGMA user_version = 2"); err != nil {
		db.Close()
		t.Fatalf("set user_version: %v", err)
	}
	db.Close()
	lib, err := library.OpenWritable(ctx, path)
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	t.Cleanup(func() { lib.Close() })
	return lib
}

// seedSource writes a source row.
func seedSource(t *testing.T, lib *library.Library, source library.Source) {
	t.Helper()
	if err := lib.UpsertSource(context.Background(), source); err != nil {
		t.Fatalf("seed source: %v", err)
	}
}

// storedSource reads one source row back.
func storedSource(t *testing.T, lib *library.Library, id string) library.Source {
	t.Helper()
	sources, err := lib.Sources(context.Background())
	if err != nil {
		t.Fatalf("read sources: %v", err)
	}
	for _, source := range sources {
		if source.ID == id {
			return source
		}
	}
	t.Fatalf("source %s not found", id)
	return library.Source{}
}
