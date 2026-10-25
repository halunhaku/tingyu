package accept

import (
	"encoding/base64"
	"fmt"
	"path/filepath"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/rangesrv"
)

// measureWindow is how long a rate or buffered sample runs.
const measureWindow = 2 * time.Second

// runControls checks rate, volume and the buffered position: three things the
// UI shows that used to be silently wrong when the engine did not report them.
func runControls(lib *mpv.Lib, mediaDir string, log func(string, ...any), report *Report) {
	localPath, missing := requireMedia(mediaDir, filepath.Join("formats", "tone.flac"))
	if missing != "" {
		skip(report, "rate", "倍速：0.5×/2× 的位置推进", missing)
		skip(report, "volume", "音量：0..1 映射", missing)
		skip(report, "buffered", "buffered 进度上报", missing)
		return
	}
	session, err := newSession(lib, nil, "", nil, log)
	if err != nil {
		skip(report, "rate", "倍速：0.5×/2× 的位置推进", "引擎创建失败："+err.Error())
		return
	}
	defer session.close()

	// --- rate ----------------------------------------------------------
	rate := Check{ID: "rate", Name: "倍速：0.5× / 2× 的位置推进", Data: map[string]any{}}
	if err := session.play([]library.Track{localTrack(localPath)}); err != nil {
		rate.Note = "起播失败：" + err.Error()
		report.Add(rate)
	} else if !waitPlaying(session, 10*time.Second) {
		rate.Note = "没有出声"
		report.Add(rate)
	} else {
		rate.Data["rateAt06"] = measureRate(session, 0.5)
		rate.Data["rateAt18"] = measureRate(session, 1.8)
		_ = session.control.SetRate(1)
		waitUntil(2*time.Second, func() bool { return within(session.snapshot().Snapshot.Rate, 1, 0.01) })
		final := session.snapshot()
		rate.Data["rateReported"] = round2(final.Snapshot.Rate)
		slow := rate.Data["rateAt06"].(map[string]any)
		fast := rate.Data["rateAt18"].(map[string]any)
		rate.Pass = final.Snapshot.Rate == 1 && ratioWithin(slow, 0.5) && ratioWithin(fast, 1.8)
		if !rate.Pass {
			rate.Note = fmt.Sprintf("expected 0.5 and 1.8, measured %v / %v", slow["advancedPerSecond"], fast["advancedPerSecond"])
		}
		log("rate: 0.5×→%v 1.8×→%v", slow["advancedPerSecond"], fast["advancedPerSecond"])
		report.Add(rate)
	}

	// --- volume --------------------------------------------------------
	volume := Check{ID: "volume", Name: "音量：0..1 映射到内核", Data: map[string]any{}}
	_ = session.control.SetVolume(0.35)
	lowSet := waitUntil(3*time.Second, func() bool {
		return within(session.snapshot().Snapshot.Volume, 0.35, 0.02)
	})
	lowValue := session.snapshot().Snapshot.Volume
	_ = session.control.SetVolume(0.8)
	highSet := waitUntil(3*time.Second, func() bool {
		return within(session.snapshot().Snapshot.Volume, 0.8, 0.02)
	})
	highValue := session.snapshot().Snapshot.Volume
	volume.Data["volumeAt035"] = round2(lowValue)
	volume.Data["volumeAt080"] = round2(highValue)
	volume.Pass = lowSet && highSet
	if !volume.Pass {
		volume.Note = fmt.Sprintf("0.35→%.2f (hit=%v), 0.8→%.2f (hit=%v)", lowValue, lowSet, highValue, highSet)
	}
	log("volume: 0.35→%.2f 0.8→%.2f", lowValue, highValue)
	report.Add(volume)

	// --- buffered, local ----------------------------------------------
	localBuffered := Check{ID: "buffered-local", Name: "buffered：本地文件不越界", Data: map[string]any{}}
	localBuffered.Pass = true
	deadline := time.Now().Add(600 * time.Millisecond)
	for time.Now().Before(deadline) {
		update := session.snapshot()
		position, buffered := update.Snapshot.Position, update.Snapshot.Buffered
		if buffered < position {
			localBuffered.Pass = false
			localBuffered.Note = fmt.Sprintf("buffered %.2fs < position %.2fs", buffered.Seconds(), position.Seconds())
			break
		}
		if update.Snapshot.Duration > 0 && buffered > update.Snapshot.Duration+100*time.Millisecond {
			localBuffered.Pass = false
			localBuffered.Note = fmt.Sprintf("buffered %.2fs > duration %.2fs", buffered.Seconds(), update.Snapshot.Duration.Seconds())
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	update := session.snapshot()
	localBuffered.Data["position"] = round2(update.Snapshot.Position.Seconds())
	localBuffered.Data["buffered"] = round2(update.Snapshot.Buffered.Seconds())
	localBuffered.Data["duration"] = round2(update.Snapshot.Duration.Seconds())
	report.Add(localBuffered)
	session.close()

	// --- buffered, remote ---------------------------------------------
	_, missing = requireMedia(mediaDir, filepath.Join("remote", "tone.flac"))
	if missing != "" {
		skip(report, "buffered-remote", "buffered：远端缓存领先播放位置", missing)
		return
	}
	server, err := rangesrv.New(rangesrv.Options{Root: mediaDir, User: sourceUser, Password: sourcePass})
	if err != nil {
		skip(report, "buffered-remote", "buffered：远端缓存领先播放位置", err.Error())
		return
	}
	if _, err := server.Start(); err != nil {
		skip(report, "buffered-remote", "buffered：远端缓存领先播放位置", err.Error())
		return
	}
	defer server.Close()
	uri := server.URL(filepath.Join("remote", "tone.flac"))
	authorization := "Basic " + base64.StdEncoding.EncodeToString([]byte(sourceUser+":"+sourcePass))
	remote, err := newSession(lib, nil, "", map[string]map[string]string{uri: {"Authorization": authorization}}, log)
	if err != nil {
		skip(report, "buffered-remote", "buffered：远端缓存领先播放位置", err.Error())
		return
	}
	defer remote.close()
	buffered := Check{ID: "buffered-remote", Name: "buffered：远端缓存领先播放位置", Data: map[string]any{"url": uri}}
	if err := remote.play([]library.Track{remoteTrack(uri, "远端缓存")}); err != nil {
		buffered.Note = "起播失败：" + err.Error()
		report.Add(buffered)
		return
	}
	if !waitPlaying(remote, 15*time.Second) {
		buffered.Note = "没有出声"
		report.Add(buffered)
		return
	}
	var aheadMax time.Duration
	observed := 0
	invalid := ""
	deadline = time.Now().Add(measureWindow)
	for time.Now().Before(deadline) {
		update := remote.snapshot()
		position, bufferedPosition := update.Snapshot.Position, update.Snapshot.Buffered
		observed++
		if bufferedPosition < position {
			invalid = fmt.Sprintf("buffered %.2fs < position %.2fs", bufferedPosition.Seconds(), position.Seconds())
			break
		}
		if ahead := bufferedPosition - position; ahead > aheadMax {
			aheadMax = ahead
		}
		time.Sleep(25 * time.Millisecond)
	}
	buffered.Data["samples"] = observed
	buffered.Data["maxAheadSeconds"] = round2(aheadMax.Seconds())
	buffered.Data["position"] = round2(remote.snapshot().Snapshot.Position.Seconds())
	buffered.Data["buffered"] = round2(remote.snapshot().Snapshot.Buffered.Seconds())
	if invalid != "" {
		buffered.Data["invalidSample"] = invalid
	}
	// A remote file with cache=yes buffers ahead of playback; a buffered value
	// that never exceeds the position would mean the UI's bar is fake.
	buffered.Pass = invalid == "" && aheadMax > 500*time.Millisecond && remote.snapshot().Failure == nil
	if !buffered.Pass && buffered.Note == "" {
		buffered.Note = fmt.Sprintf("maxAhead=%.2fs %s", aheadMax.Seconds(), invalid)
	}
	log("buffered remote: maxAhead=%.2fs samples=%d", aheadMax.Seconds(), observed)
	report.Add(buffered)
}

// measureRate changes the rate and measures how much position one wall-clock
// second produces.
func measureRate(session *session, rate float64) map[string]any {
	result := map[string]any{"rate": rate}
	if err := session.control.SetRate(rate); err != nil {
		result["error"] = err.Error()
		return result
	}
	// Let the new rate take effect before measuring.
	waitUntil(time.Second, func() bool { return within(session.snapshot().Snapshot.Rate, rate, 0.01) })
	startPosition := session.snapshot().Snapshot.Position
	started := time.Now()
	time.Sleep(measureWindow)
	endPosition := session.snapshot().Snapshot.Position
	wall := time.Since(started).Seconds()
	advanced := (endPosition - startPosition).Seconds()
	result["wallSeconds"] = round2(wall)
	result["advancedSeconds"] = round2(advanced)
	if wall > 0 {
		result["advancedPerSecond"] = round2(advanced / wall)
	}
	return result
}

func ratioWithin(sample map[string]any, expected float64) bool {
	measured, ok := sample["advancedPerSecond"].(float64)
	if !ok {
		return false
	}
	return within(measured, expected, expected*0.35)
}

func within(value, expected, tolerance float64) bool {
	difference := value - expected
	if difference < 0 {
		difference = -difference
	}
	return difference <= tolerance
}
