package components

// The column rhythm is arithmetic, so it is checked as arithmetic here rather
// than by reading a screenshot: the design's 22/44/330/170/210/弹性/56/30 at the
// 1200 wide canvas, and whole columns given up at the 900 wide minimum instead
// of a clipped row (§10-4, §11).

import (
	"testing"

	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

func TestColumnsAreTheDesignRhythm(t *testing.T) {
	// 1200 wide window: 1200 − 236 sidebar − 2×32 page inset = 900 of table.
	cols := tableColumnsFor(900, false)
	want := tableColumns{
		index:    tokens.TableIndex,
		cover:    tokens.TableCoverCol,
		title:    tokens.TableTitle,
		artist:   tokens.TableArtist,
		album:    tokens.TableAlbum,
		duration: tokens.TableDuration,
		favorite: tokens.TableFavorite,
	}
	if cols != want {
		t.Fatalf("columns = %+v, want %+v", cols, want)
	}
	if cols.index != 22 || cols.cover != 44 || cols.title != 330 || cols.artist != 170 ||
		cols.album != 210 || cols.duration != 56 || cols.favorite != 30 {
		t.Fatalf("the rhythm moved: %+v", cols)
	}
	// A second source adds its column inside the same rhythm.
	withSource := tableColumnsFor(900+130, true)
	if withSource.source != tokens.TableSource || withSource.total() != cols.total()+tokens.TableSource {
		t.Fatalf("the source column = %+v (total %v)", withSource, withSource.total())
	}
}

func TestColumnsGiveUpWholeColumnsAtTheMinimumWindow(t *testing.T) {
	// 900 wide window: 900 − 236 − 64 = 600 of table.
	cols := tableColumnsFor(600, false)
	if cols.album != 0 {
		t.Fatalf("album column = %v at the minimum width, want it dropped", cols.album)
	}
	if cols.artist != 0 {
		t.Fatalf("artist column = %v at the minimum width, want it dropped", cols.artist)
	}
	if cols.title < 160 || cols.duration != tokens.TableDuration || cols.favorite != tokens.TableFavorite {
		t.Fatalf("minimum width columns = %+v", cols)
	}
	if cols.total() > 600 {
		t.Fatalf("the minimum window's columns need %v DIP of 600", cols.total())
	}
}
