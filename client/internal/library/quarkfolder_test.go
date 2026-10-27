package library

import (
	"context"
	"github.com/egoist/mygo/plugins/sqlite"
	"testing"
)

func TestQuarkFolderPathMigrationKeepsOldReadOnlyLibrariesReadable(t *testing.T) {
	ctx := context.Background()
	path := newFixture(t, SchemaVersion, nil)
	db, err := sqlite.Open(ctx, path, sqlite.OpenOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Execute(ctx, "ALTER TABLE music_sources DROP COLUMN quark_folder_path"); err != nil {
		t.Fatal(err)
	}
	db.Close()
	ro, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = ro.Sources(ctx); err != nil {
		t.Fatal(err)
	}
	ro.Close()
	lib := openWritable(t, path)
	source := Source{ID: "q", Kind: "quark", Name: "音乐", QuarkFolderFID: "rock", QuarkFolderPath: "/音乐/摇滚"}
	if err = lib.UpsertSource(ctx, source); err != nil {
		t.Fatal(err)
	}
	all, err := lib.Sources(ctx)
	if err != nil || len(all) != 1 || all[0].QuarkFolderPath != source.QuarkFolderPath {
		t.Fatalf("path lost: %+v %v", all, err)
	}
	rows, err := lib.db.Query(ctx, "PRAGMA user_version")
	if err != nil {
		t.Fatal(err)
	}
	if int64Value(rows.Values[0][0]) != SchemaVersion {
		t.Fatal("nullable column migration changed schema version")
	}
}
