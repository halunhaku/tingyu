package accept

import (
	"fmt"
	"path/filepath"
	"sync"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
)

// queueLength is how many tracks the queue-integrity run plays end to end.
const queueLength = 200

// observation is one engine state seen while the queue played.
type observation struct {
	Index int
	Path  string
	At    time.Duration
}

// runQueue plays 200 short tracks through the real controller and checks that
// the order, the current index and the final state never drift.
func runQueue(lib *mpv.Lib, mediaDir string, log func(string, ...any), report *Report) {
	paths, missing := mediaFiles(mediaDir, "queue", queueLength)
	if missing != "" {
		skip(report, "queue-200", "连播 200 首队列不错位", missing)
		return
	}
	check := Check{ID: "queue-200", Name: "连播 200 首：顺序、当前下标、完成后状态", Data: map[string]any{"tracks": queueLength}}

	session, err := newSession(lib, nil, "", nil, log)
	if err != nil {
		check.Note = "引擎创建失败：" + err.Error()
		report.Add(check)
		return
	}
	defer session.close()
	// Halve the wall time; the queue contract does not depend on rate.
	const rate = 2.0
	if err := session.control.SetRate(rate); err != nil {
		check.Note = "设置倍速失败：" + err.Error()
		report.Add(check)
		return
	}
	check.Data["rate"] = rate

	var (
		mu       sync.Mutex
		seen     []observation
		lastPath string
	)
	events, unsubscribe := session.engine.Subscribe()
	defer unsubscribe()
	stopCapture := make(chan struct{})
	captureDone := make(chan struct{})
	go func() {
		defer close(captureDone)
		for {
			select {
			case <-stopCapture:
				return
			case snapshot, ok := <-events:
				if !ok {
					return
				}
				if snapshot.Path == "" {
					continue
				}
				mu.Lock()
				if snapshot.Path != lastPath {
					lastPath = snapshot.Path
					seen = append(seen, observation{Index: snapshot.Index, Path: snapshot.Path})
				}
				mu.Unlock()
			}
		}
	}()

	tracks := make([]library.Track, len(paths))
	for index, path := range paths {
		tracks[index] = library.Track{ID: fmt.Sprintf("q%03d", index), Title: filepath.Base(path), FilePath: path}
	}
	started := time.Now()
	if err := session.play(tracks); err != nil {
		close(stopCapture)
		<-captureDone
		check.Note = "起播失败：" + err.Error()
		report.Add(check)
		return
	}
	// Sample how far ahead the engine's playlist runs. Prefetch 2 means two
	// entries are always queued beyond the current one, except at the tail.
	depthMax := 0
	completed := false
	for deadline := time.Now().Add(120 * time.Second); time.Now().Before(deadline); {
		update := session.snapshot()
		if depth := len(session.engine.Items()) - update.Index - 1; depth > depthMax {
			depthMax = depth
		}
		if update.Snapshot.Processing == mpv.Completed {
			completed = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	// Give the capture goroutine the last snapshots.
	time.Sleep(100 * time.Millisecond)
	close(stopCapture)
	<-captureDone
	elapsed := time.Since(started)

	mu.Lock()
	observed := append([]observation(nil), seen...)
	mu.Unlock()

	// Order: the k-th observed path must be the k-th queue entry, and its
	// index must be k. Any drift (a skipped prefetch, an out-of-order append,
	// an index that does not follow the path) shows up here.
	orderMismatch := ""
	if len(observed) != len(tracks) {
		orderMismatch = fmt.Sprintf("观察到的曲目数 %d != 队列长度 %d", len(observed), len(tracks))
	}
	for index, observation := range observed {
		if orderMismatch != "" {
			break
		}
		if index >= len(tracks) {
			orderMismatch = fmt.Sprintf("多出第 %d 个观察", index+1)
			break
		}
		if observation.Path != tracks[index].FilePath {
			orderMismatch = fmt.Sprintf("第 %d 首应为 %s，实际 %s", index+1, filepath.Base(tracks[index].FilePath), filepath.Base(observation.Path))
			break
		}
		if observation.Index != index {
			orderMismatch = fmt.Sprintf("第 %d 首的当前下标为 %d", index+1, observation.Index)
			break
		}
	}

	update := session.snapshot()
	check.Data["observed"] = len(observed)
	check.Data["elapsedMs"] = elapsed.Milliseconds()
	check.Data["completed"] = completed
	check.Data["processingAtEnd"] = update.Snapshot.Processing.String()
	check.Data["playingAtEnd"] = update.Snapshot.Playing
	check.Data["indexAtEnd"] = update.Index
	check.Data["prefetchDepthMax"] = depthMax
	check.Data["queueLength"] = len(session.control.Queue())
	check.Data["failure"] = failureText(update.Failure)
	if orderMismatch != "" {
		check.Data["orderMismatch"] = orderMismatch
	}
	check.Pass = completed && orderMismatch == "" && !update.Snapshot.Playing &&
		update.Index == queueLength-1 && update.Failure == nil && depthMax >= 2
	if !check.Pass && check.Note == "" {
		check.Note = fmt.Sprintf("completed=%v index=%d/%d playing=%v %s",
			completed, update.Index, queueLength-1, update.Snapshot.Playing, orderMismatch)
	}
	log("queue: observed=%d completed=%v indexAtEnd=%d elapsed=%dms %s",
		len(observed), completed, update.Index, elapsed.Milliseconds(), orderMismatch)
	report.Add(check)
}

// runQueueReplace checks the queue contract: switching queues must stop and
// clear the old entries. playlist-clear keeps the playing item (spike §6.2),
// so a missing stop leaves the previous song in the new queue and the first
// click plays the wrong track.
func runQueueReplace(lib *mpv.Lib, mediaDir string, log func(string, ...any), report *Report) {
	paths, missing := mediaFiles(mediaDir, "queue", 6)
	if missing != "" {
		skip(report, "queue-replace", "换队列：stop → clear → append，旧队列不残留", missing)
		return
	}
	check := Check{ID: "queue-replace", Name: "换队列：stop → clear → append，旧队列不残留", Data: map[string]any{}}
	session, err := newSession(lib, nil, "", nil, log)
	if err != nil {
		check.Note = "引擎创建失败：" + err.Error()
		report.Add(check)
		return
	}
	defer session.close()

	first := make([]library.Track, len(paths[:3]))
	for index, path := range paths[:3] {
		first[index] = library.Track{ID: fmt.Sprintf("old%03d", index), Title: filepath.Base(path), FilePath: path}
	}
	second := make([]library.Track, len(paths[3:]))
	for index, path := range paths[3:] {
		second[index] = library.Track{ID: fmt.Sprintf("new%03d", index), Title: filepath.Base(path), FilePath: path}
	}
	if err := session.play(first); err != nil {
		check.Note = "起播失败：" + err.Error()
		report.Add(check)
		return
	}
	waitUntil(5*time.Second, func() bool { return len(session.engine.Items()) >= 3 })
	if err := session.play(second); err != nil {
		check.Note = "换队列失败：" + err.Error()
		report.Add(check)
		return
	}
	// Read the engine's playlist before the prefetch has a chance to pad it:
	// the entries present must all belong to the new queue.
	items := session.engine.Items()
	leftovers := 0
	for _, item := range items {
		isNew := false
		for _, track := range second {
			if item.URI == track.FilePath {
				isNew = true
				break
			}
		}
		if !isNew {
			leftovers++
		}
	}
	check.Data["engineEntries"] = len(items)
	check.Data["newQueue"] = len(second)
	check.Data["leftoverEntries"] = leftovers
	check.Data["firstURI"] = filepath.Base(items[0].URI)
	check.Data["expectedFirst"] = filepath.Base(second[0].FilePath)
	check.Pass = leftovers == 0 && len(items) <= len(second) && items[0].URI == second[0].FilePath
	if !check.Pass {
		check.Note = fmt.Sprintf("entries=%d leftovers=%d first=%s", len(items), leftovers, check.Data["firstURI"])
	}
	log("queue replace: entries=%d leftovers=%d first=%s", len(items), leftovers, check.Data["firstURI"])
	report.Add(check)
}

// runLoops checks the three loop modes and the completion state each leaves.
func runLoops(lib *mpv.Lib, mediaDir string, log func(string, ...any), report *Report) {
	paths, missing := mediaFiles(mediaDir, "queue", 3)
	if missing != "" {
		skip(report, "loop-off", "不循环：播完停在末尾并可重播", missing)
		skip(report, "loop-all", "列表循环：末尾回绕到第一首", missing)
		skip(report, "loop-one", "单曲循环：内核自己无缝循环同一文件", missing)
		return
	}
	tracks := make([]library.Track, len(paths))
	for index, path := range paths {
		tracks[index] = library.Track{ID: fmt.Sprintf("loop%03d", index), Title: filepath.Base(path), FilePath: path}
	}

	// --- off: stop at the end, play again from the top -----------------
	session, err := newSession(lib, nil, "", nil, log)
	if err != nil {
		skip(report, "loop-off", "不循环：播完停在末尾并可重播", "引擎创建失败："+err.Error())
		return
	}
	off := Check{ID: "loop-off", Name: "不循环：播完停在末尾并可重播", Data: map[string]any{}}
	session.control.SetRepeat(player.RepeatOff)
	if err := session.play(tracks[:2]); err != nil {
		off.Note = "起播失败：" + err.Error()
		report.Add(off)
		session.close()
		return
	}
	completed := waitUntil(15*time.Second, func() bool {
		return session.snapshot().Snapshot.Processing == mpv.Completed
	})
	atEnd := session.snapshot()
	off.Data["processing"] = atEnd.Snapshot.Processing.String()
	off.Data["playing"] = atEnd.Snapshot.Playing
	off.Data["index"] = atEnd.Index
	// A 0.2 s track can finish between two polls, and its position property is
	// published as 0.00 throughout; "playing again" is the contract, and the
	// loader counter proves a fresh load rather than a stale state.
	filesBefore := session.engine.FilesLoaded()
	_ = session.control.Play()
	replayed := waitUntil(8*time.Second, func() bool { return session.snapshot().Snapshot.Playing })
	afterReplay := session.snapshot()
	off.Data["replayed"] = replayed
	off.Data["filesReloaded"] = session.engine.FilesLoaded() - filesBefore
	off.Data["positionAfterReplay"] = round2(afterReplay.Snapshot.Position.Seconds())
	off.Pass = completed && !atEnd.Snapshot.Playing && replayed && afterReplay.Failure == nil
	if !off.Pass {
		off.Note = fmt.Sprintf("completed=%v playingAtEnd=%v replayed=%v", completed, atEnd.Snapshot.Playing, replayed)
	}
	log("loop off: completed=%v replayed=%v", completed, replayed)
	report.Add(off)
	session.close()

	// --- all: wrap to the first entry ----------------------------------
	session, err = newSession(lib, nil, "", nil, log)
	if err != nil {
		skip(report, "loop-all", "列表循环：末尾回绕到第一首", "引擎创建失败："+err.Error())
		return
	}
	all := Check{ID: "loop-all", Name: "列表循环：末尾回绕到第一首", Data: map[string]any{}}
	session.control.SetRepeat(player.RepeatAll)
	if err := session.play(tracks); err != nil {
		all.Note = "起播失败：" + err.Error()
		report.Add(all)
		session.close()
		return
	}
	var (
		mu            sync.Mutex
		reached       int
		reachedLast   bool
		wrappedPlayed bool
		sequence      []int
	)
	allEvents, unsubscribeAll := session.engine.Subscribe()
	stopAll := make(chan struct{})
	go func() {
		for {
			select {
			case <-stopAll:
				return
			case snapshot, ok := <-allEvents:
				if !ok {
					return
				}
				if snapshot.Path == "" {
					continue
				}
				mu.Lock()
				if len(sequence) == 0 || sequence[len(sequence)-1] != snapshot.Index {
					sequence = append(sequence, snapshot.Index)
				}
				if snapshot.Index > reached {
					reached = snapshot.Index
				}
				if snapshot.Index == len(tracks)-1 {
					reachedLast = true
				}
				if reachedLast && snapshot.Index == 0 && snapshot.Playing {
					wrappedPlayed = true
				}
				mu.Unlock()
			}
		}
	}()
	wrapSeen := waitUntil(20*time.Second, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return wrappedPlayed
	})
	mu.Lock()
	observedSequence := append([]int(nil), sequence...)
	playedAfterWrap := wrappedPlayed
	mu.Unlock()
	close(stopAll)
	unsubscribeAll()
	update := session.snapshot()
	all.Data["wrapped"] = wrapSeen
	all.Data["indexSequence"] = observedSequence
	all.Data["playingAfterWrap"] = playedAfterWrap
	all.Data["processingAfterWrap"] = update.Snapshot.Processing.String()
	all.Pass = wrapSeen && playedAfterWrap && update.Failure == nil
	if !all.Pass {
		all.Note = fmt.Sprintf("wrapped=%v seq=%v playing=%v", wrapSeen, observedSequence, update.Snapshot.Playing)
	}
	log("loop all: wrapped=%v seq=%v", wrapSeen, observedSequence)
	report.Add(all)
	session.close()

	// --- one: the engine loops the file itself --------------------------
	session, err = newSession(lib, nil, "", nil, log)
	if err != nil {
		skip(report, "loop-one", "单曲循环：内核自己无缝循环同一文件", "引擎创建失败："+err.Error())
		return
	}
	one := Check{ID: "loop-one", Name: "单曲循环：内核自己无缝循环同一文件", Data: map[string]any{}}
	// A 3 s track makes the loop point observable: the position must fall back
	// to the start without a new load and without a completed state.
	loopTrack := tracks[:1]
	if path, missing := requireMedia(mediaDir, filepath.Join("gapless", "a.flac")); missing == "" {
		loopTrack = []library.Track{localTrack(path)}
	}
	session.control.SetRepeat(player.RepeatOne)
	if err := session.play(loopTrack); err != nil {
		one.Note = "起播失败：" + err.Error()
		report.Add(one)
		session.close()
		return
	}
	if !waitPlaying(session, 10*time.Second) {
		one.Note = "没有出声"
		report.Add(one)
		session.close()
		return
	}
	firstPath := session.snapshot().Snapshot.Path
	filesLoadedBefore := session.engine.FilesLoaded()
	// Observe more than one full pass of the track: the position must wrap,
	// the path must stay, and no completion may appear.
	deadline := time.Now().Add(5 * time.Second)
	pathChanged := false
	completedDuring := false
	sawPositionReset := false
	maxPosition := time.Duration(0)
	previous := time.Duration(0)
	for time.Now().Before(deadline) {
		update := session.snapshot()
		if update.Snapshot.Path != firstPath {
			pathChanged = true
		}
		if update.Snapshot.Processing == mpv.Completed {
			completedDuring = true
		}
		if update.Snapshot.Position > maxPosition {
			maxPosition = update.Snapshot.Position
		}
		if update.Snapshot.Position+500*time.Millisecond < previous {
			sawPositionReset = true
		}
		previous = update.Snapshot.Position
		time.Sleep(10 * time.Millisecond)
	}
	final := session.snapshot()
	one.Data["path"] = filepath.Base(firstPath)
	one.Data["pathChanged"] = pathChanged
	one.Data["completedDuringLoop"] = completedDuring
	one.Data["sawPositionReset"] = sawPositionReset
	one.Data["maxPositionSeconds"] = round2(maxPosition.Seconds())
	one.Data["playing"] = final.Snapshot.Playing
	one.Data["filesLoadedDelta"] = session.engine.FilesLoaded() - filesLoadedBefore
	one.Pass = !pathChanged && !completedDuring && sawPositionReset && final.Snapshot.Playing && final.Failure == nil
	if !one.Pass {
		one.Note = fmt.Sprintf("pathChanged=%v completed=%v reset=%v playing=%v", pathChanged, completedDuring, sawPositionReset, final.Snapshot.Playing)
	}
	log("loop one: pathChanged=%v completed=%v playing=%v", pathChanged, completedDuring, final.Snapshot.Playing)
	report.Add(one)
	session.close()
}
