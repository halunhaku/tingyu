package accept

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
)

// formats are the nine extensions the scanner accepts and the kernel must play.
var formats = []string{"mp3", "flac", "m4a", "aac", "wav", "ogg", "opus", "aiff", "alac"}

// runFormats plays each format for ten seconds and then seeks to its middle.
func runFormats(lib *mpv.Lib, mediaDir string, log func(string, ...any), report *Report) {
	for _, extension := range formats {
		id := "format-" + extension
		name := "9 格式：" + extension + " 播 10 秒并 seek 到 50%"
		path, missing := requireMedia(mediaDir, filepath.Join("formats", "tone."+extension))
		if missing != "" {
			skip(report, id, name, missing)
			continue
		}
		// One core per format: the audio-device line then belongs to this file,
		// which is the difference between "the position advanced" and "this
		// format was sent to the audio device".
		var captured atomic.Value
		debug := func(format string, args ...any) {
			message := fmt.Sprintf(format, args...)
			if strings.Contains(message, "AO: [") {
				captured.Store(strings.TrimSpace(message))
			}
			// mpv's info lines are only wanted for the AO line above.
			if strings.Contains(message, "mpv: info:") {
				return
			}
			log("%s", message)
		}
		session, err := newSession(lib, nil, "info", nil, debug)
		if err != nil {
			skip(report, id, name, "引擎创建失败："+err.Error())
			continue
		}
		check := Check{ID: id, Name: name, Data: map[string]any{"format": extension, "file": path}}
		started := time.Now()
		if err := session.play([]library.Track{localTrack(path)}); err != nil {
			check.Note = "起播失败：" + err.Error()
			report.Add(check)
			session.close()
			continue
		}
		played := waitUntil(25*time.Second, func() bool {
			update := session.snapshot()
			return update.Snapshot.Playing && update.Snapshot.Position >= 10*time.Second
		})
		beforeSeek := session.snapshot()
		check.Data["playedSeconds"] = round2(beforeSeek.Snapshot.Position.Seconds())
		check.Data["durationSeconds"] = round2(beforeSeek.Snapshot.Duration.Seconds())
		check.Data["processingAfter10s"] = beforeSeek.Snapshot.Processing.String()
		check.Data["underruns"] = beforeSeek.Snapshot.Underruns

		target := beforeSeek.Snapshot.Duration / 2
		if target <= 0 {
			target = 7 * time.Second
		}
		check.Data["seekTargetSeconds"] = round2(target.Seconds())
		seekStart := time.Now()
		if err := session.control.Seek(target); err != nil && check.Note == "" {
			check.Note = "seek 失败：" + err.Error()
		}
		resumed := waitUntil(8*time.Second, func() bool {
			update := session.snapshot()
			position := update.Snapshot.Position
			return update.Snapshot.Playing && position >= target-500*time.Millisecond && position <= target+2*time.Second
		})
		afterSeek := session.snapshot()
		check.Data["seekResumeMs"] = time.Since(seekStart).Milliseconds()
		check.Data["positionAfterSeek"] = round2(afterSeek.Snapshot.Position.Seconds())
		check.Data["playingAfterSeek"] = afterSeek.Snapshot.Playing
		check.Data["elapsedMs"] = time.Since(started).Milliseconds()
		if afterSeek.Failure != nil {
			check.Data["failure"] = afterSeek.Failure.Message
			check.Data["failureDetail"] = afterSeek.Failure.Detail
		}
		aoInits := session.engine.AOInits()
		check.Data["aoInits"] = aoInits
		if line, ok := captured.Load().(string); ok {
			check.Data["audioOutput"] = line
		}
		check.Pass = played && resumed && afterSeek.Failure == nil && aoInits >= 1
		if !check.Pass && check.Note == "" {
			check.Note = fmt.Sprintf("played10s=%v seekResumed=%v aoInits=%d", played, resumed, aoInits)
		}
		log("format %-4s played=%v seek=%v pos=%.2f dur=%.2f resume=%dms ao=%d", extension, played, resumed,
			afterSeek.Snapshot.Position.Seconds(), afterSeek.Snapshot.Duration.Seconds(), time.Since(seekStart).Milliseconds(), aoInits)
		report.Add(check)
		session.close()
	}
}

func round2(value float64) float64 {
	return float64(int64(value*100+0.5)) / 100
}

// waitPlaying waits until the engine reports sound.
func waitPlaying(session *session, timeout time.Duration) bool {
	return waitUntil(timeout, func() bool { return session.snapshot().Snapshot.Playing })
}

// mediaFiles lists a directory of generated media in name order.
func mediaFiles(mediaDir, relative string, want int) ([]string, string) {
	entries, err := os.ReadDir(filepath.Join(mediaDir, relative))
	if err != nil {
		return nil, "测试媒体缺失：" + err.Error()
	}
	var paths []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		paths = append(paths, filepath.Join(mediaDir, relative, entry.Name()))
	}
	if len(paths) < want {
		return nil, fmt.Sprintf("测试媒体不足：%s 有 %d 个，需要 %d 个", relative, len(paths), want)
	}
	return paths[:want], ""
}
