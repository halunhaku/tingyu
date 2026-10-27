package model

import (
	"testing"

	"github.com/halunhaku/tingyu/client/internal/library"
)

func TestSourceFormPrefillsForRelogin(t *testing.T) {
	state := New(nil, nil, "/tmp/library.sqlite", nil)
	state.SetSources([]library.Source{{
		ID: "src-1", Name: "家里的群晖", Kind: SourceKindWebDAV,
		WebDAVURL: "https://dav.example.com/dav/", WebDAVUsername: "me",
	}})
	state.OpenSourceForm(SourceKindWebDAV, "src-1")
	form := state.SourceForm()
	if !form.Open || form.Editing != "src-1" || form.Name != "家里的群晖" ||
		form.URL != "https://dav.example.com/dav/" || form.Username != "me" {
		t.Fatalf("form not prefilled: %+v", form)
	}
	// Credentials are never prefilled: the user re-enters them.
	if form.Password != "" {
		t.Fatalf("password prefilled: %q", form.Password)
	}
	form.Name = "改过的"
	state.CloseSourceForm()
	if state.SourceForm().Open {
		t.Fatal("form still open")
	}
	if state.SourceForm().Name != "" {
		t.Fatal("closed form kept its values")
	}
}

func TestSourceErrorsDriveTheReloginEntry(t *testing.T) {
	state := New(nil, nil, "/tmp/library.sqlite", nil)
	if state.SourceError("src-1") != "" {
		t.Fatal("a fresh state has a source error")
	}
	state.SetSourceError("src-1", "夸克网盘登录凭据已失效，请重新登录")
	if got := state.SourceError("src-1"); got != "夸克网盘登录凭据已失效，请重新登录" {
		t.Fatalf("error = %q", got)
	}
	state.ClearSourceError("src-1")
	if state.SourceError("src-1") != "" {
		t.Fatal("cleared error still present")
	}
}

func TestSourceFormValuesSnapshot(t *testing.T) {
	form := SourceForm{Editing: "src-2", Name: "n", URL: "u", Username: "user", Password: "p", Cookie: "c"}
	values := form.Values()
	if values.Editing != "src-2" || values.Name != "n" || values.URL != "u" ||
		values.Username != "user" || values.Password != "p" || values.Cookie != "c" {
		t.Fatalf("values = %+v", values)
	}
}

func TestQuarkFolderPickerRejectsStaleRepliesAndKeepsReloginFolder(t *testing.T) {
	s := New(nil, nil, "/tmp/library.sqlite", nil)
	s.SetSources([]library.Source{{ID: "q", Name: "音乐", Kind: SourceKindQuark, QuarkFolderFID: "rock", QuarkFolderPath: "/音乐/摇滚"}})
	first := s.OpenQuarkFolders("q")
	if first.FolderFID != "rock" || first.FolderPath != "/音乐/摇滚" {
		t.Fatalf("relogin lost folder: %+v", first)
	}
	f := s.SourceForm()
	f.FolderTrail = append(f.FolderTrail, QuarkFolder{FID: "live", Name: "现场"})
	second := f.RequestFolders()
	if s.ApplyQuarkFolders(first, nil, "", "late error") {
		t.Fatal("late parent reply accepted")
	}
	if !s.ApplyQuarkFolders(second, []QuarkFolder{}, "test-cookie", "") || !f.FolderReady {
		t.Fatal("valid empty folder cannot be selected")
	}
	s.CloseSourceForm()
	if s.SourceForm().Cookie != "" {
		t.Fatal("closed picker retained cookie")
	}
	third := s.OpenQuarkFolders("q")
	if s.ApplyQuarkFolders(second, nil, "old-cookie", "") {
		t.Fatal("cancelled picker reply accepted")
	}
	if !s.ApplyQuarkFolders(third, nil, "", "network error") || s.SourceForm().FolderReady {
		t.Fatal("failed listing enabled confirmation")
	}
	s.InvalidateSourceFormRequest()
	if s.SourceForm().Token == third.Token {
		t.Fatal("cancel did not invalidate request")
	}
}
