package mpv

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
	"unsafe"
)

// Config 是建一个 Player 的参数。
type Config struct {
	// Options 是 mpv 启动选项（name=value），在 mpv_initialize 之前下发。
	Options map[string]string
	// LogPath 非空时把 mpv 日志行与事件写成 JSONL，作为原始证据落盘。
	LogPath string
	// VerboseEvents 为真时把所有事件（含日志行）都写进 LogPath，便于定位"不播放"这类问题。
	VerboseEvents bool
	// LogLevel 请求的 mpv 日志级别（默认 "info"）。
	LogLevel string
}

// Item 是队列里的一首歌。Options 会作为 loadfile 的 per-file options 下发
// （例如 http-header-fields）。
type Item struct {
	URI     string
	Options map[string]string
}

// Event 是被观测到的一次 mpv 事件（带本进程观测时间）。
type Event struct {
	At          time.Time `json:"at"`
	Name        string    `json:"name"`
	EndReason   int32     `json:"endReason,omitempty"`
	Err         int32     `json:"err,omitempty"`
	Property    string    `json:"property,omitempty"`
	Format      int32     `json:"format,omitempty"`
	Value       string    `json:"value,omitempty"`
	Level       string    `json:"level,omitempty"`
	Text        string    `json:"text,omitempty"`
	PlaylistPos int64     `json:"playlistPos,omitempty"`
	Userdata    uint64    `json:"userdata,omitempty"`
}

// Snapshot 是任意时刻可读的内核状态。
type Snapshot struct {
	At                  time.Time
	Paused              bool
	IdleActive          bool
	EOFReached          bool
	Position            float64
	Duration            float64
	Volume              float64
	Speed               float64
	CacheBufferingState int64
	FilesLoaded         int
	Path                string
	Underruns           int
}

// Player 是一个 mpv core 的拥有者。所有 mpv 调用线程安全；mpv_wait_event 只在
// 单一 goroutine 调用（mpv 的硬要求）。
type Player struct {
	lib *Lib
	ctx unsafe.Pointer
	log *jsonlLogger

	verbose  bool
	hookMu   sync.Mutex
	headers  map[string]string // uri → http-header-fields 值（on_load 钩子里下发）
	mu       sync.Mutex
	snap     Snapshot
	closed   bool
	closeErr error

	evMu   sync.Mutex
	events []Event
	subs   map[int]chan Event
	nextID int

	done chan struct{}
	wg   sync.WaitGroup
}

type jsonlLogger struct {
	mu sync.Mutex
	f  *os.File
}

func newJSONLLogger(path string) (*jsonlLogger, error) {
	if path == "" {
		return nil, nil
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	return &jsonlLogger{f: f}, nil
}

func (l *jsonlLogger) write(v any) {
	if l == nil {
		return
	}
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	b = append(b, '\n')
	l.mu.Lock()
	_, _ = l.f.Write(b)
	l.mu.Unlock()
}

func (l *jsonlLogger) close() {
	if l == nil {
		return
	}
	l.mu.Lock()
	_ = l.f.Close()
	l.mu.Unlock()
}

// New 建 core、下发选项、初始化、订阅属性、启动事件循环。
func New(lib *Lib, cfg Config) (*Player, error) {
	lg, err := newJSONLLogger(cfg.LogPath)
	if err != nil {
		return nil, err
	}
	ctx := lib.create()
	if ctx == nil {
		lg.close()
		return nil, errors.New("mpv_create 返回 NULL")
	}
	p := &Player{
		lib:     lib,
		ctx:     ctx,
		log:     lg,
		verbose: cfg.VerboseEvents,
		headers: map[string]string{},
		subs:    map[int]chan Event{},
		done:    make(chan struct{}),
	}
	// 选项必须在 initialize 之前。
	opts := map[string]string{
		"idle":              "yes",
		"vo":                "null",
		"audio-display":     "no",
		"gapless-audio":     "yes",
		"ao":                "coreaudio",
		"volume-max":        "100",
		"audio-client-name": "听屿Spike",
		"keep-open":         "no",
		"terminal":          "no",
		"msg-level":         "all=info",
	}
	for k, v := range cfg.Options {
		opts[k] = v
	}
	keys := make([]string, 0, len(opts))
	for k := range opts {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if rc := lib.setOptionString(ctx, bp(k), bp(opts[k])); rc < 0 {
			lg.close()
			lib.terminateDestroy(ctx)
			return nil, fmt.Errorf("set_option %s=%s: %s", k, opts[k], lib.ErrorString(rc))
		}
	}
	if rc := lib.initialize(ctx); rc < 0 {
		lg.close()
		lib.terminateDestroy(ctx)
		return nil, fmt.Errorf("mpv_initialize: %s", lib.ErrorString(rc))
	}
	level := cfg.LogLevel
	if level == "" {
		level = "info"
	}
	if rc := lib.requestLog(ctx, bp(level)); rc < 0 {
		return nil, fmt.Errorf("request_log_messages(%s): %s", level, lib.ErrorString(rc))
	}
	// on_load 钩子：在文件真正打开**之前**给 mpv 下发 http-header-fields。
	// mpv 0.36 的 loadfile 不接受第 4 个 options 参数（实测 "invalid parameter"），
	// 这也是 media_kit 在同一份 libmpv 上的做法。
	if rc := lib.hookAdd(ctx, 0, bp("on_load"), 0); rc < 0 {
		p.Close()
		return nil, fmt.Errorf("mpv_hook_add(on_load): %s", lib.ErrorString(rc))
	}

	// 订阅关心的事件源。userdata 高位编码用途，低位给 harness 自己用。
	obs := []struct {
		name   string
		format int32
		id     uint64
	}{
		{"pause", FormatFlag, 1},
		{"eof-reached", FormatFlag, 2},
		{"playback-time", FormatDouble, 3},
		{"duration", FormatDouble, 4},
		{"idle-active", FormatFlag, 5},
		{"volume", FormatDouble, 6},
		{"speed", FormatDouble, 7},
		{"cache-buffering-state", FormatInt64, 8},
		{"path", FormatString, 9},
	}
	for _, o := range obs {
		if rc := lib.observeProperty(ctx, o.id, bp(o.name), o.format); rc < 0 {
			p.Close()
			return nil, fmt.Errorf("observe %s: %s", o.name, lib.ErrorString(rc))
		}
	}
	p.log.write(map[string]any{"at": time.Now(), "kind": "init", "apiVersion": lib.ClientAPIVersion(), "options": opts})

	p.wg.Add(1)
	go p.loop()
	return p, nil
}

var propByID = map[uint64]string{
	1: "pause", 2: "eof-reached", 3: "playback-time", 4: "duration", 5: "idle-active",
	6: "volume", 7: "speed", 8: "cache-buffering-state", 9: "path",
}

// loop 是唯一调用 mpv_wait_event 的 goroutine。
func (p *Player) loop() {
	defer p.wg.Done()
	for {
		select {
		case <-p.done:
			return
		default:
		}
		evp := p.lib.waitEvent(p.ctx, 0.1)
		if evp == nil {
			continue
		}
		ev := (*cEvent)(evp)
		if ev.EventID == 0 {
			continue
		}
		now := time.Now()
		name := p.lib.EventName(ev.EventID)
		out := Event{At: now, Name: name, Userdata: ev.ReplyUserdata}
		switch name {
		case "log-message":
			if ev.Data != nil {
				lm := (*cEventLogMessage)(ev.Data)
				out.Level = goString(unsafe.Pointer(lm.Level))
				out.Text = goString(unsafe.Pointer(lm.Text))
				p.mu.Lock()
				if strings.Contains(strings.ToLower(out.Text), "underrun") {
					p.snap.Underruns++
				}
				p.mu.Unlock()
			}
		case "end-file":
			if ev.Data != nil {
				ef := (*cEventEndFile)(ev.Data)
				out.EndReason = ef.Reason
				out.Err = ef.Error
			}
			p.log.write(out)
		case "hook":
			if ev.Data != nil {
				hk := (*cEventHook)(ev.Data)
				hookName := goString(unsafe.Pointer(hk.Name))
				out.Text = hookName
				if hookName == "on_load" {
					p.applyOnLoad()
				}
				if rc := p.lib.hookContinue(p.ctx, hk.ID); rc < 0 {
					out.Level = "hook-continue-failed"
				}
			}
			p.log.write(out)
		case "property-change":
			if ev.Data != nil {
				pv := (*cEventProperty)(ev.Data)
				pname := propFromUserdata(ev.ReplyUserdata)
				out.Property = pname
				out.Format = pv.Format
				p.applyProperty(pname, pv)
			}
		case "start-file", "file-loaded", "seek", "playback-restart":
			if pos, ok := p.PropInt64("playlist-pos"); ok {
				out.PlaylistPos = pos
			}
			if name == "file-loaded" {
				p.mu.Lock()
				p.snap.FilesLoaded++
				p.mu.Unlock()
			}
			p.log.write(out)
		}
		p.publish(out)
	}
}

func propFromUserdata(u uint64) string { return propByID[u] }

func (p *Player) applyProperty(name string, pv *cEventProperty) {
	p.mu.Lock()
	defer p.mu.Unlock()
	switch pv.Format {
	case FormatFlag:
		v := *(*int32)(pv.Data) != 0
		switch name {
		case "pause":
			p.snap.Paused = v
		case "eof-reached":
			p.snap.EOFReached = v
		case "idle-active":
			p.snap.IdleActive = v
		}
	case FormatDouble:
		v := *(*float64)(pv.Data)
		switch name {
		case "playback-time":
			p.snap.Position = v
		case "duration":
			p.snap.Duration = v
		case "volume":
			p.snap.Volume = v
		case "speed":
			p.snap.Speed = v
		}
	case FormatInt64:
		v := *(*int64)(pv.Data)
		if name == "cache-buffering-state" {
			p.snap.CacheBufferingState = v
		}
	case FormatString:
		// MPV_FORMAT_STRING 的 data 是 char**（指向字符串的指针），不是 char*。
		// 直接当 char* 读会拿到指针本身的字节 —— 第一版就是这样把标题读成乱码的。
		if name == "path" && pv.Data != nil {
			p.snap.Path = goString(*(*unsafe.Pointer)(pv.Data))
		}
	}
	p.snap.At = time.Now()
}

func (p *Player) publish(e Event) {
	if p.verbose {
		p.log.write(e)
	}
	p.evMu.Lock()
	p.events = append(p.events, e)
	if len(p.events) > 4000 {
		p.events = p.events[len(p.events)-4000:]
	}
	subs := make([]chan Event, 0, len(p.subs))
	for _, ch := range p.subs {
		subs = append(subs, ch)
	}
	p.evMu.Unlock()
	for _, ch := range subs {
		select {
		case ch <- e:
		default:
		}
	}
}

// Subscribe 返回事件流与取消函数。
func (p *Player) Subscribe() (<-chan Event, func()) {
	ch := make(chan Event, 256)
	p.evMu.Lock()
	id := p.nextID
	p.nextID++
	p.subs[id] = ch
	p.evMu.Unlock()
	return ch, func() {
		p.evMu.Lock()
		delete(p.subs, id)
		p.evMu.Unlock()
	}
}

// Events 返回已观测事件（拷贝）。
func (p *Player) Events() []Event {
	p.evMu.Lock()
	defer p.evMu.Unlock()
	out := make([]Event, len(p.events))
	copy(out, p.events)
	return out
}

// Snapshot 读取当前状态。
func (p *Player) Snapshot() Snapshot {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.snap
}

// Command 下发一条 mpv 命令。
func (p *Player) Command(args ...string) error {
	cargs := make([]*byte, len(args)+1)
	for i, a := range args {
		cargs[i] = bp(a)
	}
	rc := p.lib.command(p.ctx, &cargs[0])
	if rc < 0 {
		return fmt.Errorf("mpv command %v: %s", args, p.lib.ErrorString(rc))
	}
	return nil
}

// optionString 把 per-file options 编码成 mpv 的 key=value,key=value 形式。
func optionString(m map[string]string) string {
	if len(m) == 0 {
		return ""
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, k+"="+m[k])
	}
	return strings.Join(parts, ",")
}

// LoadFile 下发 loadfile。mode: "replace" 或 "append"。
// 有 per-file options 时按 `loadfile <url> <mode> -1 <options>` 下发
// （mpv 0.36 支持第 4 个参数；spike 的阈值 4 就是实测这条）。
func (p *Player) LoadFile(uri string, mode string, opts map[string]string) error {
	if mode == "" {
		mode = "replace"
	}
	args := []string{"loadfile", uri, mode}
	if os := optionString(opts); os != "" {
		args = append(args, "-1", os)
	}
	return p.Command(args...)
}

// SetHeaderFor 给某个 URI 登记 per-file 的 http-header-fields 值（例如
// "Authorization: Basic xxx"）。在 on_load 钩子里按当前 path 下发。
func (p *Player) SetHeaderFor(uri, headerValue string) {
	p.hookMu.Lock()
	defer p.hookMu.Unlock()
	if headerValue == "" {
		delete(p.headers, uri)
		return
	}
	p.headers[uri] = headerValue
}

// ClearHeaders 清空所有登记的头。
func (p *Player) ClearHeaders() {
	p.hookMu.Lock()
	defer p.hookMu.Unlock()
	p.headers = map[string]string{}
}

// applyOnLoad 在 on_load 钩子里读 path 并下发对应头；没有登记就不动。
func (p *Player) applyOnLoad() {
	path, ok := p.PropString("path")
	if !ok || path == "" {
		return
	}
	p.hookMu.Lock()
	hv, found := p.headers[path]
	p.hookMu.Unlock()
	if !found {
		return
	}
	if err := p.SetPropertyString("http-header-fields", hv); err != nil {
		p.log.write(map[string]any{"at": time.Now(), "kind": "on_load_header_failed", "path": path, "err": err.Error()})
		return
	}
	p.log.write(map[string]any{"at": time.Now(), "kind": "on_load_header_set", "path": path})
}

// ClearPlaylist 清空队列（不复建 core）。
func (p *Player) ClearPlaylist() error { return p.Command("playlist-clear") }

// SetPaused 暂停/继续。
func (p *Player) SetPaused(paused bool) error {
	v := "no"
	if paused {
		v = "yes"
	}
	return p.SetPropertyString("pause", v)
}

// SetPropertyString 设属性。
func (p *Player) SetPropertyString(name, value string) error {
	rc := p.lib.setPropertyString(p.ctx, bp(name), bp(value))
	if rc < 0 {
		return fmt.Errorf("set_property %s=%s: %s", name, value, p.lib.ErrorString(rc))
	}
	return nil
}

// Seek 绝对跳转（秒）。
func (p *Player) Seek(seconds float64) error {
	return p.Command("seek", fmt.Sprintf("%.3f", seconds), "absolute")
}

// SetVolume 0..1（内部映射到 mpv 的 0..100）。
func (p *Player) SetVolume(v float64) error {
	if v < 0 {
		v = 0
	}
	if v > 1 {
		v = 1
	}
	return p.SetPropertyString("volume", fmt.Sprintf("%.2f", v*100))
}

// SetSpeed 倍速。
func (p *Player) SetSpeed(s float64) error {
	return p.SetPropertyString("speed", fmt.Sprintf("%.3f", s))
}

// SetLoopFile 单曲循环（loop-file=inf）。
func (p *Player) SetLoopFile(on bool) error {
	if on {
		return p.SetPropertyString("loop-file", "inf")
	}
	return p.SetPropertyString("loop-file", "no")
}

// PropInt64 同步读 int64 属性。
func (p *Player) PropInt64(name string) (int64, bool) {
	var v int64
	rc := p.lib.getProperty(p.ctx, bp(name), FormatInt64, unsafe.Pointer(&v))
	if rc < 0 {
		return 0, false
	}
	return v, true
}

// PropString 同步读字符串属性。
func (p *Player) PropString(name string) (string, bool) {
	ptr := p.lib.getPropertyString(p.ctx, bp(name))
	if ptr == nil {
		return "", false
	}
	s := goString(ptr)
	p.lib.free(ptr)
	return s, true
}

// PropFlag 同步读 bool 属性（mpv 的 FLAG 是 int*）。
func (p *Player) PropFlag(name string) (bool, bool) {
	var v int32
	if rc := p.lib.getProperty(p.ctx, bp(name), FormatFlag, unsafe.Pointer(&v)); rc < 0 {
		return false, false
	}
	return v != 0, true
}

// PropDouble 同步读 double 属性。
func (p *Player) PropDouble(name string) (float64, bool) {
	var v float64
	if rc := p.lib.getProperty(p.ctx, bp(name), FormatDouble, unsafe.Pointer(&v)); rc < 0 {
		return 0, false
	}
	return v, true
}

// DebugProps 用 mpv_get_property 与 mpv_get_property_string 两条路各读一遍，
// 返回 "name=value" 列表，供 FFI 排障。
func (p *Player) DebugProps(names []string) []string {
	out := make([]string, 0, len(names))
	for _, n := range names {
		var d float64
		var i int64
		var f int32
		rcD := p.lib.getProperty(p.ctx, bp(n), FormatDouble, unsafe.Pointer(&d))
		rcI := p.lib.getProperty(p.ctx, bp(n), FormatInt64, unsafe.Pointer(&i))
		rcF := p.lib.getProperty(p.ctx, bp(n), FormatFlag, unsafe.Pointer(&f))
		out = append(out, fmt.Sprintf("%s: double(rc=%d)=%v int64(rc=%d)=%d flag(rc=%d)=%d",
			n, rcD, d, rcI, i, rcF, f))
	}
	return out
}

// WaitEvent 等某个事件名，超时返回 false。
func (p *Player) WaitEvent(name string, timeout time.Duration) (Event, bool) {
	ch, cancel := p.Subscribe()
	defer cancel()
	deadline := time.After(timeout)
	for {
		select {
		case e := <-ch:
			if e.Name == name {
				return e, true
			}
		case <-deadline:
			return Event{}, false
		}
	}
}

// WaitPosition 等 playback-time 达到至少 pos。
func (p *Player) WaitPosition(pos float64, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if p.Snapshot().Position >= pos {
			return true
		}
		time.Sleep(2 * time.Millisecond)
	}
	return false
}

// Close 终止 core 并等事件循环退出。
func (p *Player) Close() error {
	p.mu.Lock()
	if p.closed {
		err := p.closeErr
		p.mu.Unlock()
		return err
	}
	p.closed = true
	p.mu.Unlock()
	close(p.done)
	p.wg.Wait()
	p.lib.terminateDestroy(p.ctx)
	p.log.write(map[string]any{"at": time.Now(), "kind": "closed"})
	p.log.close()
	return nil
}
