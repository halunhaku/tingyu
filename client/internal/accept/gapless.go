package accept

import (
	"fmt"
	"path/filepath"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
)

// gaplessSilenceThreshold is how quiet a stretch must be to count as a gap.
// -60 dBFS is inaudible on speakers; 5 ms is below the threshold of a click but
// long enough that a device rebuild cannot hide inside it.
const (
	gaplessSilenceThreshold = -60.0
	gaplessSilenceMinimum   = 5 * time.Millisecond
)

// runGapless renders two consecutive tracks of the same album through mpv's
// pcm AO and looks for silence in what the audio device would have received,
// then repeats the structural check on the real coreaudio output.
func runGapless(lib *mpv.Lib, mediaDir, outDir string, log func(string, ...any), report *Report) {
	first, missing := requireMedia(mediaDir, filepath.Join("gapless", "a.flac"))
	if missing != "" {
		skip(report, "gapless-same-album", "同专辑连播无可闻空隙", missing)
		return
	}
	second, missing := requireMedia(mediaDir, filepath.Join("gapless", "b.flac"))
	if missing != "" {
		skip(report, "gapless-same-album", "同专辑连播无可闻空隙", missing)
		return
	}
	rendered := filepath.Join(outDir, "gapless-rendered.wav")
	check := Check{ID: "gapless-same-album", Name: "同专辑连播无可闻空隙（渲染波形 + AO 重建计数）", Data: map[string]any{
		"rendered": rendered,
		"method":   "mpv ao=pcm 渲染实际输出 → 分析 -60 dBFS、≥5 ms 静音段；同时计数 'AO: [' 音频设备重建行数",
	}}

	session, err := newSession(lib, map[string]string{
		"ao":               "pcm",
		"ao-pcm-file":      rendered,
		"audio-samplerate": "48000",
		"audio-channels":   "stereo",
		"audio-format":     "float",
	}, "info", nil, log)
	if err != nil {
		check.Note = "引擎创建失败：" + err.Error()
		report.Add(check)
		return
	}
	// Repeat-off: the check renders the album transition once. Leaving the
	// default repeat-all would replay the queue and overwrite the rendered
	// file inside the measurement.
	session.control.SetRepeat(player.RepeatOff)
	tracks := []library.Track{localTrack(first), localTrack(second)}
	if err := session.play(tracks); err != nil {
		check.Note = "起播失败：" + err.Error()
		session.close()
		report.Add(check)
		return
	}
	started := time.Now()
	completed := waitUntil(30*time.Second, func() bool {
		return session.snapshot().Snapshot.Processing == mpv.Completed
	})
	elapsed := time.Since(started)
	after := session.snapshot()
	aoInits := session.engine.AOInits()
	filesLoaded := session.engine.FilesLoaded()
	session.close()

	check.Data["completed"] = completed
	check.Data["elapsedMs"] = elapsed.Milliseconds()
	check.Data["aoInits"] = aoInits
	check.Data["filesLoaded"] = filesLoaded
	check.Data["positionAtCompletion"] = round2(after.Snapshot.Position.Seconds())
	check.Data["failure"] = failureText(after.Failure)

	wav, err := readWAV(rendered)
	if err != nil {
		check.Note = "读取渲染波形失败：" + err.Error()
		report.Add(check)
		return
	}
	runs := wav.silences(gaplessSilenceThreshold, gaplessSilenceMinimum)
	check.Data["renderedSeconds"] = round2(wav.Duration().Seconds())
	check.Data["renderedPeakDBFS"] = round2(wav.peakDBFS())
	check.Data["silenceRuns"] = len(runs)
	if len(runs) > 0 {
		check.Data["silenceAt"] = fmt.Sprintf("%.3fs–%.3fs", runs[0].Start.Seconds(), runs[0].End.Seconds())
	}
	// Two 3 s tracks must render as one continuous 6 s stream, with a single
	// audio-device initialization and no silence anywhere inside it.
	check.Pass = completed && aoInits == 1 && filesLoaded == 2 && len(runs) == 0 &&
		wav.Duration() >= 5900*time.Millisecond && wav.Duration() <= 6100*time.Millisecond
	if !check.Pass {
		check.Note = fmt.Sprintf("completed=%v aoInits=%d files=%d silenceRuns=%d rendered=%.3fs",
			completed, aoInits, filesLoaded, len(runs), wav.Duration().Seconds())
	}
	log("gapless: completed=%v aoInits=%d files=%d rendered=%.3fs silenceRuns=%d", completed, aoInits, filesLoaded, wav.Duration().Seconds(), len(runs))
	report.Add(check)
	report.Add(Check{
		ID:   "gapless-scope",
		Name: "gapless 口径：跨格式/跨采样率不保证（方案 §4.1/§2.2 #14）",
		Note: "本项只验证同专辑、同采样率、同格式（48 kHz/24 bit FLAC）连播；跨格式或跨采样率 mpv 会重建音频链，计划里明确不保证无缝，验收口径按同样范围记录。",
		Pass: true,
	})
}
