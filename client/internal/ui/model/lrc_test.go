package model

import (
	"testing"
	"time"
)

// A BOM glued to the first line used to hide that line's timestamp, so the
// whole document was shown as plain text.
func TestParseLRCLeadingBOMSingleSyncedLine(t *testing.T) {
	lyrics := ParseLRC("\ufeff[00:01.50]第一句")
	if !lyrics.Synced {
		t.Fatalf("Synced = false, want true")
	}
	if len(lyrics.Lines) != 1 {
		t.Fatalf("len(Lines) = %d, want 1", len(lyrics.Lines))
	}
	if got := lyrics.Lines[0].Time; got != 1500*time.Millisecond {
		t.Errorf("Time = %v, want 1.5s", got)
	}
	if got := lyrics.Lines[0].Text; got != "第一句" {
		t.Errorf("Text = %q, want %q", got, "第一句")
	}
}

// Dropping the marker must not swallow any of the following lines, including
// CRLF-separated ones.
func TestParseLRCLeadingBOMKeepsThreeCRLFLines(t *testing.T) {
	lyrics := ParseLRC("\ufeff[00:01.00]第一句\r\n[00:05.00]第二句\r\n[00:09.00]第三句")
	if !lyrics.Synced {
		t.Fatalf("Synced = false, want true")
	}
	want := []LyricLine{
		{Time: 1 * time.Second, Text: "第一句"},
		{Time: 5 * time.Second, Text: "第二句"},
		{Time: 9 * time.Second, Text: "第三句"},
	}
	if len(lyrics.Lines) != len(want) {
		t.Fatalf("len(Lines) = %d, want %d", len(lyrics.Lines), len(want))
	}
	for i, expected := range want {
		if got := lyrics.Lines[i].Time; got != expected.Time {
			t.Errorf("Lines[%d].Time = %v, want %v", i, got, expected.Time)
		}
		if got := lyrics.Lines[i].Text; got != expected.Text {
			t.Errorf("Lines[%d].Text = %q, want %q", i, got, expected.Text)
		}
	}
	if lyrics.Plain != "" {
		t.Errorf("Plain = %q, want empty", lyrics.Plain)
	}
}

// Plain text keeps its text, minus the document-leading marker only.
func TestParseLRCLeadingBOMPlainText(t *testing.T) {
	lyrics := ParseLRC("\ufeff第一行\n第二行\ufeff尾巴")
	if lyrics.Synced {
		t.Fatalf("Synced = true, want false")
	}
	if len(lyrics.Lines) != 0 {
		t.Errorf("len(Lines) = %d, want 0", len(lyrics.Lines))
	}
	if want := "第一行\n第二行\ufeff尾巴"; lyrics.Plain != want {
		t.Errorf("Plain = %q, want %q", lyrics.Plain, want)
	}
}

func TestParseLRCOnlyBOM(t *testing.T) {
	lyrics := ParseLRC("\ufeff")
	if lyrics.Synced {
		t.Errorf("Synced = true, want false")
	}
	if len(lyrics.Lines) != 0 {
		t.Errorf("len(Lines) = %d, want 0", len(lyrics.Lines))
	}
	if lyrics.Plain != "" {
		t.Errorf("Plain = %q, want empty", lyrics.Plain)
	}
}

// The marker also hid a leading ID tag, which then leaked into Plain. A tag
// followed by timed lines already passed before the fix, so the tag must be
// alone here to be regression evidence.
func TestParseLRCLeadingBOMBeforeIDTag(t *testing.T) {
	lyrics := ParseLRC("\ufeff[ar:艺术家]")
	if lyrics.Synced {
		t.Errorf("Synced = true, want false")
	}
	if len(lyrics.Lines) != 0 {
		t.Errorf("len(Lines) = %d, want 0", len(lyrics.Lines))
	}
	if lyrics.Plain != "" {
		t.Errorf("Plain = %q, want empty", lyrics.Plain)
	}
}
