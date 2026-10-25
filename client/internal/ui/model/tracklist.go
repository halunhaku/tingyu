package model

import (
	"sort"
	"strings"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// Filter selects the rows of a list.
type Filter int

const (
	FilterAll Filter = iota
	FilterFavorites
)

// SortField is the library sort (track_sort.dart).
type SortField int

const (
	SortTitle SortField = iota
	SortArtist
	SortAlbum
	SortDuration
	SortAdded
)

// String is the label the sort menu shows.
func (f SortField) String() string {
	switch f {
	case SortArtist:
		return "艺术家"
	case SortAlbum:
		return "专辑"
	case SortDuration:
		return "时长"
	case SortAdded:
		return "最近添加"
	default:
		return "曲名"
	}
}

// Next cycles through the five fields.
func (f SortField) Next() SortField { return (f + 1) % 5 }

// RowKey is a table row's identity: the track and its row revision. A
// metadata-only change bumps the revision and rebuilds that row alone — the
// audit's missing refresh trigger, fixed in the immediate-mode world.
type RowKey struct {
	ID  string
	Rev uint64
}

// TrackList is one paginated, filtered, sorted list of tracks. It implements
// the plan's §2.5 refresh contract: one page per trigger, a loading/done gate
// that never builds an empty page, and a content revision that re-filters in
// place while keeping the pages loaded so far.
type TrackList struct {
	filter   Filter
	query    string
	sourceID string
	sortBy   SortField
	asc      bool

	pages   int
	loading bool
	done    bool
	total   int

	filtered []library.Track
	built    string
	builtRev uint64
	config   string

	table    ui.ListState
	selected int
}

// Configure changes the view (filter, source, sort). It resets pagination to
// page one, as Flutter does when the URL query changes.
func (t *TrackList) Configure(filter Filter, sortBy SortField, asc bool, sourceID string) {
	config := listKey(filter, t.query, sourceID, sortBy, asc)
	if t.config != "" && t.config != config {
		t.pages = 1
		t.selected = -1
	}
	t.filter = filter
	t.sortBy = sortBy
	t.asc = asc
	t.sourceID = sourceID
	t.config = config
}

// SetQuery adds a text filter (the search page reuses the list).
func (t *TrackList) SetQuery(query string) {
	config := listKey(t.filter, query, t.sourceID, t.sortBy, t.asc)
	if t.config != "" && t.config != config {
		t.pages = 1
		t.selected = -1
	}
	t.query = query
	t.config = config
}

func listKey(filter Filter, query, source string, sortBy SortField, asc bool) string {
	return string(rune('0'+filter)) + "|" + query + "|" + source + "|" + string(rune('0'+sortBy)) + "|" + boolKey(asc)
}

func boolKey(v bool) string {
	if v {
		return "1"
	}
	return "0"
}

// Ensure recomputes the filtered, sorted rows when the revision (or the
// configuration) changed. Page count is preserved across revisions so a
// metadata write does not throw the reader back to the top; it is clamped when
// the library shrank.
func (t *TrackList) Ensure(tracks []library.Track, revision uint64, rowRevs map[string]uint64) {
	if t.pages == 0 {
		t.pages = 1
	}
	// The table header's sort arrives through ListState.Sort; mirror it into
	// the model order (the table shows rows in the order the app gives them).
	if sort := t.table.Sort; sort != nil && sort.Column != "" {
		field := SortTitle
		switch sort.Column {
		case "artist":
			field = SortArtist
		case "album":
			field = SortAlbum
		case "duration":
			field = SortDuration
		}
		asc := !sort.Descending
		if field != t.sortBy || asc != t.asc {
			t.sortBy, t.asc = field, asc
			t.config = listKey(t.filter, t.query, t.sourceID, t.sortBy, t.asc)
			t.pages = 1
		}
	}
	key := t.config + "#" + itoa(revision)
	if key == t.built {
		return
	}
	t.built = key
	t.builtRev = revision
	out := make([]library.Track, 0, len(tracks))
	needle := strings.ToLower(strings.TrimSpace(t.query))
	for _, track := range tracks {
		if t.filter == FilterFavorites && !track.IsFavorite {
			continue
		}
		if t.sourceID != "" && track.SourceID != t.sourceID {
			continue
		}
		if needle != "" && !trackMatches(track, needle) {
			continue
		}
		out = append(out, track)
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		var less bool
		switch t.sortBy {
		case SortArtist:
			less = fold(a.Artist) < fold(b.Artist) || (fold(a.Artist) == fold(b.Artist) && fold(a.Album) < fold(b.Album))
		case SortAlbum:
			less = fold(a.Album) < fold(b.Album)
		case SortDuration:
			less = a.Duration < b.Duration
		case SortAdded:
			less = a.DateAdded.Before(b.DateAdded)
		default:
			less = fold(a.Title) < fold(b.Title)
		}
		if fold(a.Title) == fold(b.Title) && fold(a.Artist) == fold(b.Artist) {
			// A stable tie-break keeps the order reproducible between frames.
			return strings.Compare(a.Artist+a.Album+a.ID, b.Artist+b.Album+b.ID) < 0
		}
		if t.asc {
			return less
		}
		return !less
	})
	t.filtered = out
	t.total = len(out)
	if t.pages*PageSize >= t.total {
		t.done = true
		t.pages = max(1, (t.total+PageSize-1)/PageSize)
	}
	if t.pages < 1 {
		t.pages = 1
	}
	t.table.Key = func(row int) any {
		items := t.Items()
		if row < 0 || row >= len(items) {
			return row
		}
		return RowKey{ID: items[row].ID, Rev: rowRevs[items[row].ID]}
	}
	t.table.Label = func(row int) string {
		items := t.Items()
		if row < 0 || row >= len(items) {
			return ""
		}
		return items[row].Title
	}
}

func trackMatches(track library.Track, needle string) bool {
	return strings.Contains(fold(track.Title), needle) ||
		strings.Contains(fold(track.Artist), needle) ||
		strings.Contains(fold(track.Album), needle)
}

func fold(s string) string { return strings.ToLower(s) }

// Items are the rows loaded so far (pages × PageSize).
func (t *TrackList) Items() []library.Track {
	limit := min(len(t.filtered), t.pages*PageSize)
	if limit < 0 {
		return nil
	}
	return t.filtered[:limit]
}

// All returns every matching row, regardless of pages: 「播放全部」must play
// the whole query, not only the loaded pages (providers.dart behavior).
func (t *TrackList) All() []library.Track { return t.filtered }

// Total is the number of matching rows.
func (t *TrackList) Total() int { return t.total }

// Loaded is how many rows are in the table.
func (t *TrackList) Loaded() int { return len(t.Items()) }

// Page is the pages loaded.
func (t *TrackList) Page() int { return t.pages }

// Loading reports a page being built.
func (t *TrackList) Loading() bool { return t.loading }

// Done reports that no more pages exist.
func (t *TrackList) Done() bool { return t.done }

// RequestMore asks for one more page. Repeated calls while a page is pending
// are ignored: the scroll listener fires many times per frame, and the old
// client built a provider per event (audit §2.5).
func (t *TrackList) RequestMore() {
	if t.loading || t.done || t.total == 0 {
		return
	}
	if t.pages*PageSize >= t.total {
		t.done = true
		return
	}
	t.loading = true
}

// Step commits a pending page. The shell runs it once per frame, so a trigger
// yields exactly one page.
func (t *TrackList) Step() {
	if !t.loading {
		return
	}
	t.loading = false
	if t.pages*PageSize < t.total {
		t.pages++
	}
	if t.pages*PageSize >= t.total {
		t.done = true
	}
}

// LoadAll loads every page. Acceptance uses it to scroll the whole library;
// the UI never does this on its own (pagination exists for that).
func (t *TrackList) LoadAll() {
	t.loading = false
	if t.total == 0 {
		return
	}
	t.pages = (t.total + PageSize - 1) / PageSize
	t.done = true
}

// Selected returns the table's chosen row.
func (t *TrackList) Selected() int { return t.selected }

// SetSelected sets the table's chosen row.
func (t *TrackList) SetSelected(row int) { t.selected = row }

// Table is the list state pages bind to ui.Table.
func (t *TrackList) Table() *ui.ListState { return &t.table }

// BindTable binds the list's chosen row to the model and returns the state.
func (t *TrackList) BindTable() *ui.ListState {
	t.table.Selected = &t.selected
	return &t.table
}

// Sort returns the current sort field.
func (t *TrackList) Sort() SortField { return t.sortBy }

// Asc reports the sort direction.
func (t *TrackList) Asc() bool { return t.asc }

// SetSort changes the sort and returns to page one.
func (t *TrackList) SetSort(field SortField, asc bool) {
	t.Configure(t.filter, field, asc, t.sourceID)
}

// Filter returns the current filter.
func (t *TrackList) Filter() Filter { return t.filter }

// SetSource changes the source filter and returns to page one.
func (t *TrackList) SetSource(sourceID string) {
	t.Configure(t.filter, t.sortBy, t.asc, sourceID)
}

// Selection is the track at the chosen row, or false.
func (t *TrackList) Selection() (library.Track, bool) {
	items := t.Items()
	if t.selected < 0 || t.selected >= len(items) {
		return library.Track{}, false
	}
	return items[t.selected], true
}

// MaybeRequestMore is the scroll gate: near the end of the loaded rows, ask
// for the next page. Call it after the table was built (Visible needs it).
func (t *TrackList) MaybeRequestMore() {
	first, last := t.table.Visible()
	if first < 0 || last < 0 {
		return
	}
	if last >= len(t.Items())-8 || t.table.AtEnd() {
		t.RequestMore()
	}
}

func itoa(v uint64) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}

// Library returns the library page's list.
func (s *State) Library() *TrackList { return &s.library }

// Favorites returns the favorites page's list.
func (s *State) Favorites() *TrackList { return &s.favorites }

// FavoriteView returns 0 for songs and 1 for albums.
func (s *State) FavoriteView() int { return s.favoriteView }

// SetFavoriteView selects the favorites segment.
func (s *State) SetFavoriteView(v int) { s.favoriteView = v }

// SourceFilter returns the library page's source filter.
func (s *State) SourceFilter() string { return s.library.sourceID }

// HasMultipleSources reports whether the source filter is worth showing.
func (s *State) HasMultipleSources() bool { return len(s.sources) > 1 }
