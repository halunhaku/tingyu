package accept

import (
	"encoding/base64"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/rangesrv"
)

// sourceUser and sourcePass are what the acceptance source demands; the
// kernel receives them as a per-track Authorization header through the
// on_load hook, never as a Go-side audio proxy.
const (
	sourceUser = "tingyu"
	sourcePass = "m2-acceptance"
)

// runRemote proves remote playback, seeking over Range, per-track
// authentication, and the failure/recovery cycle a user actually hits:
// a rejected or expired link, and a network that goes away and comes back.
func runRemote(lib *mpv.Lib, mediaDir, outDir string, log func(string, ...any), report *Report) {
	_, missing := requireMedia(mediaDir, filepath.Join("remote", "tone.flac"))
	if missing != "" {
		skip(report, "remote-play", "远端播放与 Range seek", missing)
		skip(report, "remote-auth", "按曲目下发鉴权头", missing)
		skip(report, "remote-expired", "直链过期提示与恢复", missing)
		skip(report, "remote-offline", "断网提示与恢复", missing)
		skip(report, "remote-unknown-duration", "未知时长不等于 loading", missing)
		return
	}

	server, err := rangesrv.New(rangesrv.Options{
		Root:         mediaDir,
		User:         sourceUser,
		Password:     sourcePass,
		RequireRange: true,
		LogPath:      filepath.Join(outDir, "remote-requests.jsonl"),
	})
	if err != nil {
		skip(report, "remote-play", "远端播放与 Range seek", "测试服务创建失败："+err.Error())
		return
	}
	if _, err := server.Start(); err != nil {
		skip(report, "remote-play", "远端播放与 Range seek", "测试服务启动失败："+err.Error())
		return
	}
	defer server.Close()

	uri := server.URL(filepath.Join("remote", "tone.flac"))
	secondURL := server.URL(filepath.Join("remote", "second.flac"))
	streamURL := server.URL(filepath.Join("remote", "nolength.aac"))
	authorization := "Basic " + base64.StdEncoding.EncodeToString([]byte(sourceUser+":"+sourcePass))
	headers := map[string]map[string]string{
		uri:       {"Authorization": authorization},
		streamURL: {"Authorization": authorization},
	}
	// A small demuxer cache forces the seek to cross an uncached region, so
	// the server really sees Range requests instead of answering from memory.
	session, err := newSession(lib, map[string]string{
		"cache":                  "yes",
		"demuxer-max-bytes":      "1048576",
		"demuxer-readahead-secs": "1",
	}, "", headers, log)
	if err != nil {
		skip(report, "remote-play", "远端播放与 Range seek", "引擎创建失败："+err.Error())
		return
	}
	defer session.close()

	// --- play, then seek to the middle ---------------------------------
	playCheck := Check{ID: "remote-play", Name: "远端曲目可播（本地校验服务）", Data: map[string]any{"url": uri}}
	if err := session.play([]library.Track{remoteTrack(uri, "远端 测试曲")}); err != nil {
		playCheck.Note = "起播失败：" + err.Error()
		report.Add(playCheck)
	} else {
		started := time.Now()
		playing := waitUntil(12*time.Second, func() bool {
			update := session.snapshot()
			return update.Snapshot.Playing && update.Snapshot.Position >= 2*time.Second
		})
		position := session.snapshot()
		playCheck.Data["secondsToTwoSecondsOfAudio"] = time.Since(started).Milliseconds()
		playCheck.Data["durationSeconds"] = round2(position.Snapshot.Duration.Seconds())
		playCheck.Data["position"] = round2(position.Snapshot.Position.Seconds())

		seekTarget := position.Snapshot.Duration / 2
		if seekTarget <= 0 {
			seekTarget = 10 * time.Second
		}
		beforeRecords := len(server.Records())
		seekStart := time.Now()
		_ = session.control.Seek(seekTarget)
		resumed := waitUntil(8*time.Second, func() bool {
			update := session.snapshot()
			return update.Snapshot.Playing && update.Snapshot.Position >= seekTarget-500*time.Millisecond
		})
		after := session.snapshot()
		playCheck.Data["seekTargetSeconds"] = round2(seekTarget.Seconds())
		playCheck.Data["positionAfterSeek"] = round2(after.Snapshot.Position.Seconds())
		playCheck.Data["seekResumeMs"] = time.Since(seekStart).Milliseconds()

		records := server.Records()
		rangeRequests := 0
		partial := 0
		authorized := 0
		requestsAfterSeek := 0
		for index, record := range records {
			if record.Range != "" {
				rangeRequests++
			}
			if record.Status == 206 {
				partial++
			}
			if record.Authorized {
				authorized++
			}
			if index >= beforeRecords {
				requestsAfterSeek++
			}
		}
		playCheck.Data["requests"] = len(records)
		playCheck.Data["rangeRequests"] = rangeRequests
		playCheck.Data["partialResponses"] = partial
		playCheck.Data["authorizedRequests"] = authorized
		playCheck.Data["requestsAfterSeek"] = requestsAfterSeek
		playCheck.Pass = playing && resumed && after.Failure == nil && rangeRequests > 0 && partial > 0 && requestsAfterSeek > 0
		if !playCheck.Pass {
			playCheck.Note = fmt.Sprintf("playing=%v seekResumed=%v range=%d partial=%d", playing, resumed, rangeRequests, partial)
		}
		log("remote: playing=%v seek=%.2f range=%d partial=%d resume=%dms", playing, seekTarget.Seconds(), rangeRequests, partial, time.Since(seekStart).Milliseconds())
		report.Add(playCheck)
	}

	// --- authentication is per track, not sticky ------------------------
	// A *different* URL without headers: re-playing the same URL would let mpv
	// reuse its demuxer and prove nothing (observed during M2).
	authCheck := Check{ID: "remote-auth", Name: "按曲目下发鉴权头（无头即 401）", Data: map[string]any{"url": secondURL}}
	if err := session.play([]library.Track{remoteTrack(secondURL, "同一来源里没有鉴权头的下一首")}); err == nil {
		failed := waitUntil(12*time.Second, func() bool {
			failure := session.snapshot().Failure
			return failure != nil && failure.Status == 401
		})
		update := session.snapshot()
		authCheck.Data["failure"] = failureText(update.Failure)
		authCheck.Data["failKind"] = failureKind(update.Failure)
		authCheck.Data["failureStatus"] = failureStatus(update.Failure)
		authCheck.Data["playingAfterFailure"] = update.Snapshot.Playing
		authCheck.Data["processingAfterFailure"] = update.Snapshot.Processing.String()
		records := server.Records()
		last := records[len(records)-1]
		authCheck.Data["lastRequestAuthorization"] = last.Authorization
		authCheck.Data["lastRequestStatus"] = last.Status
		authCheck.Data["requestsForSecondURL"] = requestsFor(records, "/remote/second.flac")
		// The previous track's Authorization must not have been reused: that
		// is the whole point of clearing http-header-fields per file.
		authCheck.Pass = failed && !update.Snapshot.Playing && last.Authorization == "" && last.Status == 401
		if !authCheck.Pass {
			authCheck.Note = fmt.Sprintf("failed=%v lastAuth=%q status=%d", failed, last.Authorization, last.Status)
		}
	}
	report.Add(authCheck)

	// --- expired direct link (403), then recovery -----------------------
	expiredCheck := Check{ID: "remote-expired", Name: "直链过期（403）提示，恢复后可继续播", Data: map[string]any{}}
	server.SetMode(rangesrv.ModeForbidden)
	if err := session.play([]library.Track{remoteTrack(uri, "过期直链")}); err == nil {
		failed := waitUntil(12*time.Second, func() bool {
			failure := session.snapshot().Failure
			return failure != nil && failure.Status == 403
		})
		update := session.snapshot()
		expiredCheck.Data["failure"] = failureText(update.Failure)
		expiredCheck.Data["failKind"] = failureKind(update.Failure)
		expiredCheck.Data["failureStatus"] = failureStatus(update.Failure)
		expiredCheck.Data["noException"] = true
		server.SetMode(rangesrv.ModeAllow)
		_ = session.control.Play()
		recovered := waitUntil(15*time.Second, func() bool {
			update := session.snapshot()
			return update.Snapshot.Playing && update.Failure == nil && update.Snapshot.Position > 0
		})
		after := session.snapshot()
		expiredCheck.Data["recovered"] = recovered
		expiredCheck.Data["positionAfterRecovery"] = round2(after.Snapshot.Position.Seconds())
		expiredCheck.Data["failureAfterRecovery"] = failureText(after.Failure)
		expiredCheck.Pass = failed && recovered && after.Failure == nil
		if !expiredCheck.Pass {
			expiredCheck.Note = fmt.Sprintf("failed403=%v recovered=%v", failed, recovered)
		}
	}
	report.Add(expiredCheck)

	// --- network gone, then back ----------------------------------------
	offlineCheck := Check{ID: "remote-offline", Name: "断网提示，恢复后可继续播", Data: map[string]any{}}
	_ = session.control.Pause()
	if err := server.Stop(); err != nil {
		offlineCheck.Note = "关闭测试服务失败：" + err.Error()
		report.Add(offlineCheck)
	} else {
		if err := session.play([]library.Track{remoteTrack(uri, "断网中")}); err == nil {
			failed := waitUntil(15*time.Second, func() bool {
				failure := session.snapshot().Failure
				return failure != nil && failure.Kind == mpv.FailureNetwork
			})
			update := session.snapshot()
			offlineCheck.Data["failure"] = failureText(update.Failure)
			offlineCheck.Data["failKind"] = failureKind(update.Failure)
			if _, err := server.Restart(); err != nil {
				offlineCheck.Note = "重启测试服务失败：" + err.Error()
			} else {
				_ = session.control.Play()
				recovered := waitUntil(15*time.Second, func() bool {
					update := session.snapshot()
					return update.Snapshot.Playing && update.Failure == nil && update.Snapshot.Position > 0
				})
				after := session.snapshot()
				offlineCheck.Data["recovered"] = recovered
				offlineCheck.Data["positionAfterRecovery"] = round2(after.Snapshot.Position.Seconds())
				offlineCheck.Pass = failed && recovered && after.Failure == nil
				if !offlineCheck.Pass {
					offlineCheck.Note = fmt.Sprintf("failedNetwork=%v recovered=%v", failed, recovered)
				}
			}
		}
	}
	report.Add(offlineCheck)

	// --- no Content-Length must not mean "loading" -----------------------
	durationCheck := Check{ID: "remote-unknown-duration", Name: "无 Content-Length 的远端流：播放中报 ready，不因缺长度而 loading", Data: map[string]any{"url": streamURL}}
	if _, missing := requireMedia(mediaDir, filepath.Join("remote", "nolength.aac")); missing != "" {
		durationCheck.Skipped = true
		durationCheck.Note = missing
		report.Add(durationCheck)
	} else {
		server.SetMode(rangesrv.ModeChunked)
		if err := session.play([]library.Track{remoteTrack(streamURL, "无长度流")}); err == nil {
			playing := waitUntil(20*time.Second, func() bool {
				update := session.snapshot()
				return update.Snapshot.Playing && update.Snapshot.Position >= 2*time.Second
			})
			update := session.snapshot()
			durationCheck.Data["durationSeconds"] = round2(update.Snapshot.Duration.Seconds())
			durationCheck.Data["processingWhilePlaying"] = update.Snapshot.Processing.String()
			durationCheck.Data["playing"] = update.Snapshot.Playing
			durationCheck.Data["position"] = round2(update.Snapshot.Position.Seconds())
			durationCheck.Data["durationSource"] = "容器无时长（ADTS），mpv 按码率估算；真正的未知时长由 mpv.state 单测覆盖"
			durationCheck.Pass = playing && update.Snapshot.Processing == mpv.Ready && update.Failure == nil
			if !durationCheck.Pass {
				durationCheck.Note = fmt.Sprintf("playing=%v processing=%s", playing, update.Snapshot.Processing)
			}
		}
		server.SetMode(rangesrv.ModeAllow)
		report.Add(durationCheck)
	}
}

func remoteTrack(uri, title string) library.Track {
	return library.Track{ID: uri, Title: title, FilePath: uri, Duration: 20 * time.Second}
}

func failureText(failure *mpv.Failure) string {
	if failure == nil {
		return ""
	}
	return failure.Message
}

func failureKind(failure *mpv.Failure) string {
	if failure == nil {
		return ""
	}
	return failure.Kind.String()
}

func failureStatus(failure *mpv.Failure) int {
	if failure == nil {
		return 0
	}
	return failure.Status
}

// requestsFor counts the recorded requests whose path ends with suffix.
func requestsFor(records []rangesrv.Request, suffix string) int {
	count := 0
	for _, record := range records {
		if strings.HasSuffix(record.Path, suffix) {
			count++
		}
	}
	return count
}
