package main

// glyphs.go is the icon vocabulary of the stills. It adds the glyphs the
// redesign needs in the same 24-unit outline vocabulary the app's own icons
// use (client/internal/ui/components/icons.go), so the stills do not invent a
// second visual language.

import "github.com/egoist/mygo/ui"

func stroke(body string) *ui.SVG {
	return ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">` + body + `</svg>`))
}

func solid(body string) *ui.SVG {
	return ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" stroke="none">` + body + `</svg>`))
}

var (
	glyphPlay     = solid(`<path d="M8 5.5v13l11-6.5z"/>`)
	glyphPause    = solid(`<rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/>`)
	glyphPrev     = solid(`<path d="M18 5.5v13L9 12z"/><rect x="4.5" y="5" width="2.5" height="14" rx="1"/>`)
	glyphNext     = solid(`<path d="M6 5.5v13l9-6.5z"/><rect x="17" y="5" width="2.5" height="14" rx="1"/>`)
	glyphShuffle  = stroke(`<path d="M2 18h3l4-5 4 5h3"/><path d="m18 14 3 4-3 4"/><path d="M2 6h3l9 12h4"/><path d="m18 2 3 4-3 4"/>`)
	glyphRepeat   = stroke(`<path d="m17 2 4 4-4 4"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><path d="m7 22-4-4 4-4"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/>`)
	glyphHeart    = stroke(`<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.6l-1-1a5.5 5.5 0 0 0-7.8 7.8l1 1L12 21l7.8-7.6 1-1a5.5 5.5 0 0 0 0-7.8z"/>`)
	glyphHeartOn  = solid(`<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.6l-1-1a5.5 5.5 0 0 0-7.8 7.8l1 1L12 21l7.8-7.6 1-1a5.5 5.5 0 0 0 0-7.8z"/>`)
	glyphSearch   = stroke(`<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>`)
	glyphSettings = stroke(`<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.9.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.9 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.9.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.9-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.9V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>`)
	glyphMore     = solid(`<circle cx="5" cy="12" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="19" cy="12" r="1.8"/>`)
	glyphBack     = stroke(`<path d="m15 18-6-6 6-6"/>`)
	glyphClose    = stroke(`<path d="M18 6 6 18"/><path d="m6 6 12 12"/>`)
	glyphPlus     = stroke(`<path d="M12 5v14"/><path d="M5 12h14"/>`)
	glyphFolder   = stroke(`<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>`)
	glyphNote     = solid(`<path d="M9 18V5l11-2v13a3 3 0 1 1-2-2.8V6.5L11 8v10a3 3 0 1 1-2-2.8z"/>`)
	glyphQueue    = stroke(`<path d="M3 6h11"/><path d="M3 12h11"/><path d="M3 18h7"/><path d="m16 12 5 3-5 3z"/>`)
	glyphLyrics   = stroke(`<path d="M4 5h16"/><path d="M4 10h12"/><path d="M4 15h16"/><path d="M4 20h8"/>`)
	glyphCheck    = stroke(`<path d="m5 12 4 4L19 6"/>`)
	glyphInfo     = stroke(`<circle cx="12" cy="12" r="9"/><path d="M12 11v5"/><path d="M12 8h.01"/>`)
	glyphUp       = stroke(`<path d="m18 15-6-6-6 6"/>`)
	glyphDown     = stroke(`<path d="m6 9 6 6 6-6"/>`)
	glyphExternal = stroke(`<path d="M14 4h6v6"/><path d="M20 4 10 14"/><path d="M20 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h5"/>`)

	// The glyphs the redesign adds, in the same 24-unit outline style.
	glyphLibrary  = stroke(`<path d="M4 5h5v14H4z"/><path d="M9 5h5v14H9z"/><path d="m14.5 6 4.2 12"/>`)
	glyphAlbum    = stroke(`<rect x="4" y="4" width="16" height="16" rx="3"/><circle cx="12" cy="12" r="3.6"/>`)
	glyphArtist   = stroke(`<circle cx="12" cy="8" r="4"/><path d="M5 21c0-3.9 3.1-7 7-7s7 3.1 7 7"/>`)
	glyphPlaylist = stroke(`<path d="M4 6h10"/><path d="M4 12h10"/><path d="M4 18h6"/><path d="m16 14 5 3-5 3z"/>`)
	glyphVolume   = stroke(`<path d="M4 10v4h3l4 4V6L7 10z"/><path d="M16 9a4 4 0 0 1 0 6"/>`)
	glyphList     = stroke(`<path d="M4 6h16"/><path d="M4 12h16"/><path d="M4 18h10"/>`)
	glyphGrid     = stroke(`<rect x="4" y="4" width="6" height="6" rx="1"/><rect x="14" y="4" width="6" height="6" rx="1"/><rect x="4" y="14" width="6" height="6" rx="1"/><rect x="14" y="14" width="6" height="6" rx="1"/>`)
)
