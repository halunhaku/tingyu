package model

import (
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

// SortField is the library sort (track_sort.dart). The order matches
// library.SortField; sortQuery maps one to the other explicitly rather than
// relying on the numeric agreement.
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

// sortQuery maps the UI's sort to the kernel's.
func (f SortField) sortQuery() library.SortField {
	switch f {
	case SortArtist:
		return library.SortArtist
	case SortAlbum:
		return library.SortAlbum
	case SortDuration:
		return library.SortDuration
	case SortAdded:
		return library.SortAdded
	default:
		return library.SortTitle
	}
}

// RowKey is a table row's identity: the track, its row revision and — for a
// playlist, which may hold the same track twice — the row it occupies. A
// metadata-only change bumps the revision and rebuilds that row alone, which is
// the audit's missing refresh trigger fixed in the immediate-mode world.
type RowKey struct {
	ID  string
	Rev uint64
	Pos int
}

// TrackList is one paginated, filtered, sorted list of tracks. It is the plan's
// §2.5 refresh contract on top of SQL paging:
//
//   - the rows are a LIMIT/OFFSET page from the kernel, never a filtered copy
//     of the whole table;
//   - one page per trigger, a loading/done gate that never builds an empty
//     page, and a page count that survives a revision (a metadata write does
//     not throw the reader back to the top);
//   - the query key carries the library revision, so any write refreshes the
//     loaded window, and each row's key carries the row revision, so a
//     metadata-only change rebuilds that row and nothing else.
type TrackList struct {
	filter     Filter
	query      string
	sourceID   string
	playlistID string
	sortBy     SortField
	asc        bool

	pages   int  // pages the list wants to show
	more    bool // a page was requested and has not been committed yet
	want    int  // the page count the gate asked for
	loading bool // a request is in flight
	done    bool // no page beyond the loaded rows exists
	total   int
	rows    []library.Track
	// built is the key of the rows currently held; builtBase is their query
	// without the page count (the window may grow on top of them).
	built   string
	request string // key of the in-flight request
	pending <-chan library.TrackPage
	// requestBase is the in-flight request's query without its page count.
	requestBase string
	// appendPage marks a request that only adds rows past the held ones.
	appendPage bool
	err        string
	rowRev     func(id string) uint64
	table      ui.ListState
	selected   int
	builtBase  string
}

// SetRowRevision installs the per-row revision source used by row keys.
func (t *TrackList) SetRowRevision(fn func(id string) uint64) {
	t.rowRev = fn
}

// Configure changes the view (filter, source, sort). It resets pagination to
// page one, as Flutter does when the URL query changes.
func (t *TrackList) Configure(filter Filter, sortBy SortField, asc bool, sourceID string) {
	defer t.bind()
	key := t.configKey(filter, t.query, sourceID, t.playlistID, sortBy, asc)
	if t.configKey(t.filter, t.query, t.sourceID, t.playlistID, t.sortBy, t.asc) != key {
		t.reset()
	}
	t.filter = filter
	t.sortBy = sortBy
	t.asc = asc
	t.sourceID = sourceID
}

func (t *TrackList) configKey(filter Filter, query, source, playlist string, sortBy SortField, asc bool) string {
	return itoa(uint64(filter)) + "|" + query + "|" + source + "|" + playlist + "|" +
		itoa(uint64(sortBy)) + "|" + boolKey(asc)
}

func boolKey(v bool) string {
	if v {
		return "1"
	}
	return "0"
}

// reset returns the list to one page with nothing loaded.
func (t *TrackList) reset() {
	t.pages = 1
	t.more = false
	t.done = false
	t.total = 0
	t.rows = nil
	t.built = ""
	t.builtBase = ""
	t.request = ""
	t.selected = -1
}

// Query is the list's text filter (the library page's field and the search
// page read it back to draw their inputs).
func (t *TrackList) Query() string { return t.query }

// SetQuery adds a text filter (the search page reuses the list).
func (t *TrackList) SetQuery(query string) {
	key := t.configKey(t.filter, query, t.sourceID, t.playlistID, t.sortBy, t.asc)
	if t.configKey(t.filter, t.query, t.sourceID, t.playlistID, t.sortBy, t.asc) != key {
		t.reset()
	}
	t.query = query
}

// SetPlaylist turns the list into a playlist page: its saved order, no sort.
func (t *TrackList) SetPlaylist(id string) {
	if t.playlistID != id {
		t.reset()
	}
	t.playlistID = id
}

// kernelQuery is the query for the loaded window (pages × PageSize).
func (t *TrackList) kernelQuery() library.TrackQuery {
	q := library.TrackQuery{
		SourceID:   t.sourceID,
		PlaylistID: t.playlistID,
		Search:     t.query,
		Sort:       t.sortBy.sortQuery(),
		Desc:       !t.asc,
		Limit:      t.pages * PageSize,
	}
	if t.filter == FilterFavorites {
		q.Favorite = true
	}
	return q
}

// baseKey identifies the query (filter, text, sort, revision) without its page
// count: a page-count change reuses the request already in flight.
func (t *TrackList) baseKey(revision, epoch uint64) string {
	return t.configKey(t.filter, t.query, t.sourceID, t.playlistID, t.sortBy, t.asc) +
		"#" + itoa(revision) + "." + itoa(epoch)
}

// key identifies the rows this list wants right now.
func (t *TrackList) key(revision, epoch uint64) string {
	return t.baseKey(revision, epoch) + "." + itoa(uint64(t.pages))
}

// pageRequest is the query for the wanted window. Growing the window on the
// rows the list already holds asks only for the rows past them (OFFSET =
// loaded): a query returning the whole loaded window again on every page would
// make a long scroll quadratic in transferred rows.
//
// Appending is only valid while the held rows answer the same query (same
// base, which carries the library revision): after a write the window must be
// re-read from the start, or the rows already held would keep their old
// favourite flags, play counts and titles.
func (t *TrackList) pageRequest(base string) library.TrackQuery {
	q := t.kernelQuery()
	if t.builtBase == base && len(t.rows) > 0 && t.pages*PageSize > len(t.rows) {
		q.Offset = len(t.rows)
		q.Limit = t.pages*PageSize - len(t.rows)
		t.appendPage = true
		return q
	}
	t.appendPage = false
	return q
}

// Tick applies an arrived page, commits one requested page and, when the rows
// held do not match the current key, asks the kernel for them. The shell runs
// it once per frame.
func (t *TrackList) Tick(load Backend, revision, epoch uint64) {
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
			t.Configure(t.filter, field, asc, t.sourceID)
		}
	}
	t.poll()
	t.step()
	if load == nil {
		return
	}
	key := t.key(revision, epoch)
	if key == t.built {
		return
	}
	if t.pending != nil {
		if t.request == key {
			return
		}
		if t.baseKey(revision, epoch) == t.requestBase {
			// Same query, another page count: let the running request land
			// (it holds usable rows) and ask for the wider window next frame.
			// Starting over every frame would starve a fast scroll.
			return
		}
		// The in-flight request answers a query nobody wants any more (a
		// write arrived, or the filter changed): drop it. Its goroutine still
		// delivers into the buffered channel, so abandoning it cannot block
		// anything.
		t.pending = nil
		t.loading = false
	}
	t.request = key
	t.requestBase = t.baseKey(revision, epoch)
	t.loading = true
	t.pending = load.LoadTracks(t.pageRequest(t.requestBase))
	t.poll()
}

// poll applies a page that has already arrived (a backend that answers in the
// same frame delivers it before the first frame that shows the rows).
func (t *TrackList) poll() {
	if t.pending == nil {
		return
	}
	select {
	case page := <-t.pending:
		t.pending = nil
		t.loading = false
		if page.Err != nil {
			t.err = page.Err.Error()
			t.built = t.request
			return
		}
		t.err = ""
		if t.appendPage {
			t.rows = append(t.rows, page.Rows...)
		} else {
			t.rows = page.Rows
		}
		t.appendPage = false
		t.total = page.Total
		if len(t.rows) == 0 || len(t.rows) >= t.total {
			t.done = true
		} else {
			t.done = false
		}
		// The arrived window is a lower bound of what the reader asked for: a
		// bigger page count may have been committed while this query ran.
		if arrived := (len(t.rows) + PageSize - 1) / PageSize; arrived > t.pages {
			t.pages = arrived
		}
		t.pages = max(1, t.pages)
		t.built = t.request
		t.builtBase = t.requestBase
	default:
	}
}

// step commits the pages the gate asked for, once per frame (the scroll
// listener fires many times per frame; the old client built a provider per
// event, audit §2.5).
func (t *TrackList) step() {
	if !t.more {
		return
	}
	t.more = false
	if t.done {
		return
	}
	if t.want > t.pages {
		t.pages = t.want
	}
	t.want = 0
}

// bind installs the row identity closures. They read t.rows when the list
// asks, so a page that arrives does not reinstall them: the table keeps the
// function values it was given for the whole life of the list.
func (t *TrackList) bind() {
	if t.table.Key != nil {
		return
	}
	t.table.Key = func(row int) any {
		if row < 0 || row >= len(t.rows) {
			return row
		}
		rev := uint64(0)
		if t.rowRev != nil {
			rev = t.rowRev(t.rows[row].ID)
		}
		// A playlist is the one list that can show a track twice (it may hold
		// the same song in two places), so its row is part of the identity.
		if t.playlistID != "" {
			return RowKey{ID: t.rows[row].ID, Rev: rev, Pos: row}
		}
		return RowKey{ID: t.rows[row].ID, Rev: rev}
	}
	t.table.Label = func(row int) string {
		if row < 0 || row >= len(t.rows) {
			return ""
		}
		return t.rows[row].Title
	}
}

func trackMatches(track library.Track, needle string) bool {
	return strings.Contains(fold(track.Title), needle) ||
		strings.Contains(fold(track.Artist), needle) ||
		strings.Contains(fold(track.Album), needle)
}

func fold(s string) string { return strings.ToLower(s) }

// Items are the rows loaded so far.
func (t *TrackList) Items() []library.Track { return t.rows }

// Total is the true number of matching rows.
func (t *TrackList) Total() int { return t.total }

// Loaded is how many rows are in the table.
func (t *TrackList) Loaded() int { return len(t.rows) }

// Page is the pages requested.
func (t *TrackList) Page() int { return t.pages }

// Loading reports a page request in flight.
func (t *TrackList) Loading() bool { return t.loading || t.more }

// Done reports that no more pages exist.
func (t *TrackList) Done() bool { return t.done }

// Err is the last page request's failure, if any.
func (t *TrackList) Err() string { return t.err }

// settled reports that the rows held answer the current key and nothing is in
// flight (used by the window's acceptance harness to wait for a page).
func (t *TrackList) settled(revision, epoch uint64) bool {
	return t.pending == nil && t.built != "" && t.built == t.key(revision, epoch)
}

// RequestMore asks for one more page (the pager footer's button). Repeated
// calls while a page is pending are ignored.
func (t *TrackList) RequestMore() { t.RequestRowsUpTo(t.pages*PageSize + PageSize) }

// RequestRowsUpTo asks for enough pages to show rows: a fast scroll or a jump
// asks once for the window it reached instead of a page per frame.
func (t *TrackList) RequestRowsUpTo(rows int) {
	if t.done || t.total == 0 {
		return
	}
	if t.pages*PageSize >= t.total {
		t.done = true
		return
	}
	need := max(1, (rows+PageSize-1)/PageSize)
	if need <= t.pages {
		return
	}
	t.more = true
	t.want = max(t.want, need)
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

// SourceFilter returns the source the list is filtered to, or "".
func (t *TrackList) SourceFilter() string { return t.sourceID }

// SetSource changes the source filter and returns to page one.
func (t *TrackList) SetSource(sourceID string) {
	t.Configure(t.filter, t.sortBy, t.asc, sourceID)
}

// MaybeRequestMore is the scroll gate: near the end of the loaded rows, ask
// for the next page. Call it after the table was built (Visible needs it).
func (t *TrackList) MaybeRequestMore() {
	first, last := t.table.Visible()
	if first < 0 || last < 0 {
		return
	}
	if last >= len(t.rows)-8 || t.table.AtEnd() {
		// Ask for the window the reader reached plus two pages ahead: at the
		// edge of the loaded rows a fast scroll needs a running start, or it
		// keeps hitting the end while one page is in flight.
		t.RequestRowsUpTo(last + 2*PageSize)
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

// Recent returns the "最近添加" shelf's list: the whole library, newest
// added first, asked one page at a time exactly as the table asks for its rows.
func (s *State) Recent() *TrackList { return &s.recent }

// Favorites returns the favorites page's list.
func (s *State) Favorites() *TrackList { return &s.favorites }

// PlaylistTracks returns the open playlist's list.
func (s *State) PlaylistTracks() *TrackList {
	if s.playlistDetail == nil {
		return &s.library
	}
	return &s.playlistDetail.Tracks
}

// FavoriteView returns 0 for songs and 1 for albums.
func (s *State) FavoriteView() int { return s.favoriteView }

// SetFavoriteView selects the favorites segment.
func (s *State) SetFavoriteView(v int) { s.favoriteView = v }

// SourceFilter returns the library page's source filter.
func (s *State) SourceFilter() string { return s.library.sourceID }

// HasMultipleSources reports whether the source filter is worth showing.
func (s *State) HasMultipleSources() bool { return len(s.sources) > 1 }
