// Package components holds the shared desktop widgets.
package components

import (
	"embed"
	"github.com/egoist/mygo/ui"
)

// Sound Island (A), approved 2026-10-27: 24-unit grid, 1.8-unit rounded strokes.
// Embedded SVG files are the runtime source; currentColor follows the UI theme.
//
//go:embed icons/*.svg
var iconFiles embed.FS

func loadIcon(name string) *ui.SVG {
	data, err := iconFiles.ReadFile("icons/" + name + ".svg")
	if err != nil {
		panic(err)
	}
	return ui.MustParseSVG(data)
}

var (
	IconPlay     = loadIcon("play")
	IconPause    = loadIcon("pause")
	IconNext     = loadIcon("next")
	IconPrev     = loadIcon("previous")
	IconHeart    = loadIcon("heart")
	IconHeartOn  = loadIcon("heart-filled")
	IconSearch   = loadIcon("search")
	IconSettings = loadIcon("settings")
	IconQueue    = loadIcon("queue")
	IconLyrics   = loadIcon("lyrics")
	IconBack     = loadIcon("back")
	IconForward  = loadIcon("forward")
	IconMore     = loadIcon("more")
	IconPlus     = loadIcon("plus")
	IconMusic    = loadIcon("music")
	IconFolder   = loadIcon("folder")
	IconClose    = loadIcon("close")
	IconUp       = loadIcon("up")
	IconDown     = loadIcon("down")
	IconExternal = loadIcon("external")
	IconCheck    = loadIcon("check")
	IconInfo     = loadIcon("info")
	IconRepeat   = loadIcon("repeat")
	IconVolume   = loadIcon("volume")
	IconLibrary  = loadIcon("library")
	IconAlbum    = loadIcon("album")
	IconArtist   = loadIcon("artist")
	IconPlaylist = loadIcon("playlist")
	IconShuffle  = loadIcon("shuffle")
	IconMinimize = loadIcon("down")
	IconBrand    = loadIcon("brand")
	IconCloud    = loadIcon("cloud")
	IconWebDAV   = loadIcon("webdav")
	IconSync     = loadIcon("sync")
	IconRecent   = loadIcon("recent")
)

// SourceIcon keeps the sidebar and source cards consistent.
func SourceIcon(kind string) *ui.SVG {
	switch kind {
	case "webdav":
		return IconWebDAV
	case "quark":
		return IconCloud
	default:
		return IconFolder
	}
}
