package model

import (
	"fmt"
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
)

// FormatDuration shows 3:49, or 1:02:03 past an hour.
func FormatDuration(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	seconds := int64(d / time.Second)
	if seconds >= 3600 {
		return fmt.Sprintf("%d:%02d:%02d", seconds/3600, seconds%3600/60, seconds%60)
	}
	return fmt.Sprintf("%d:%02d", seconds/60, seconds%60)
}

// FormatTotal is the human total of a group, e.g. "42 分钟".
func FormatTotal(d time.Duration) string {
	minutes := int(d / time.Minute)
	if minutes >= 60 {
		return fmt.Sprintf("%d 小时 %d 分钟", minutes/60, minutes%60)
	}
	return fmt.Sprintf("%d 分钟", minutes)
}

func trackCountLabel(n int) string { return fmt.Sprintf("%d 首", n) }

func albumCountLabel(n int) string { return fmt.Sprintf("%d 张", n) }

// StatusText is the one-line playback state for the stage header.
func StatusText(update player.Update) string {
	if update.Failure != nil {
		return "播放失败"
	}
	switch update.Snapshot.Processing {
	case mpv.Loading:
		return "正在加载"
	case mpv.Buffering:
		return "正在缓冲"
	}
	if update.Snapshot.Playing {
		return "正在播放"
	}
	if update.Track != nil {
		return "已暂停"
	}
	return "未在播放"
}

// RepeatLabel is the transport's repeat label (list/one/off).
func RepeatLabel(mode player.RepeatMode) string {
	switch mode {
	case player.RepeatOne:
		return "单曲循环"
	case player.RepeatOff:
		return "不循环"
	default:
		return "列表循环"
	}
}

// RepeatNext is the next label in the all → one → off cycle, for tooltips.
func RepeatNext(mode player.RepeatMode) string {
	switch mode {
	case player.RepeatAll:
		return "单曲循环"
	case player.RepeatOne:
		return "不循环"
	default:
		return "列表循环"
	}
}

// ShuffleLabel is the shuffle button's state label.
func ShuffleLabel(on bool) string {
	if on {
		return "开"
	}
	return "关"
}

// TrackSubtitle is "artist · album", skipping empty parts.
func TrackSubtitle(track library.Track) string {
	parts := make([]string, 0, 2)
	if track.Artist != "" {
		parts = append(parts, track.Artist)
	}
	if track.Album != "" {
		parts = append(parts, track.Album)
	}
	return strings.Join(parts, " · ")
}

// SourceName resolves a source ID for a table cell.
func (s *State) SourceName(id string) string {
	for _, source := range s.sources {
		if source.ID == id {
			return source.Name
		}
	}
	if id == "" {
		return "本地"
	}
	return id
}
