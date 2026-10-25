// spike-np 用 macOS 的 **私有** MediaRemote 框架查询/驱动系统的"正在播放"，
// 用来回答 S2 里靠自读回答不了的问题：
//
//   - 系统到底把这台机器的 Now Playing 归给了哪个进程（pid）？
//   - 控制中心那块 tile 里的内容是什么（系统侧的字典，而不是我们自己写进去的）？
//   - 媒体键/控制中心按钮真的能打到我们的 MPRemoteCommandCenter 回调上吗？
//     （MRMediaRemoteSendCommand 与硬件媒体键走同一条命令分发路径）
//
// 之所以是私有 API：这些能力没有公开的等价物，而"tile 是否显示"必须从系统侧看。
// 因此这个工具只用于验证，不进入产品代码。
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"runtime"
	"strings"
	"time"
	"unsafe"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
)

var (
	getNowPlayingInfo     func(queue uintptr, block objc.Block)
	getNowPlayingAppPID   func(queue uintptr, block objc.Block)
	getNowPlayingPlaying  func(queue uintptr, block objc.Block)
	sendRemoteCommand     func(cmd int32, info objc.ID) int8
	dispatchQueueCreate   func(label *byte, attr uintptr) uintptr
	dispatchSemaphoreWait func(sem uintptr, timeout uint64) int64
)

func main() {
	info := flag.Bool("info", false, "打印系统侧 Now Playing（pid / 是否在播 / 字典）")
	send := flag.String("send", "", "发一条远程命令：play|pause|toggle|stop|next|prev|seek")
	seekTo := flag.Float64("seek", 0, "-send seek 时的目标秒数")
	watch := flag.Duration("watch", 0, "持续轮询这么久（例如 20s）")
	repeat := flag.Int("repeat", 1, "-send 重复次数（阈值 6 的 100 次连按）")
	gap := flag.Duration("gap", 30*time.Millisecond, "-send 重复的间隔")
	interval := flag.Duration("interval", 500*time.Millisecond, "-watch 的轮询间隔")
	flag.Parse()

	if err := load(); err != nil {
		fmt.Fprintf(os.Stderr, "加载 MediaRemote 失败: %v\n", err)
		os.Exit(2)
	}

	switch {
	case *info:
		printState()
	case *send != "":
		code, ok := commandCode(*send)
		if !ok {
			fmt.Fprintf(os.Stderr, "未知命令 %q\n", *send)
			os.Exit(2)
		}
		var payload objc.ID
		switch *send {
		case "seek":
			payload = positionInfo("kMRMediaRemoteOptionPlaybackPosition", *seekTo)
		case "seekus":
			payload = positionInfo("kMRMediaRemoteOptionPlaybackPositionMicroseconds", *seekTo*1e6)
		}
		// 发送时间戳记到毫秒，用来和被测进程日志里的 MARK 时间戳对齐算延迟。
		start := time.Now()
		accepted := 0
		for i := range *repeat {
			if *repeat > 1 {
				start = time.Now()
			}
			if rc := sendRemoteCommand(code, payload); rc != 0 {
				accepted++
			}
			if *repeat > 1 && i < *repeat-1 {
				time.Sleep(*gap)
			}
		}
		fmt.Printf("send %s ×%d at %s → 接受 %d 次\n", *send, *repeat,
			start.Format("15:04:05.000"), accepted)
		time.Sleep(300 * time.Millisecond)
		if *repeat == 1 {
			printState()
		}
	default:
		deadline := time.Now().Add(*watch)
		for {
			printState()
			if *watch == 0 || time.Now().After(deadline) {
				return
			}
			time.Sleep(*interval)
		}
	}
}

func load() error {
	h, err := purego.Dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
		purego.RTLD_LAZY|purego.RTLD_GLOBAL)
	if err != nil {
		return err
	}
	purego.RegisterLibFunc(&getNowPlayingInfo, h, "MRMediaRemoteGetNowPlayingInfo")
	purego.RegisterLibFunc(&getNowPlayingAppPID, h, "MRMediaRemoteGetNowPlayingApplicationPID")
	purego.RegisterLibFunc(&getNowPlayingPlaying, h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying")
	purego.RegisterLibFunc(&sendRemoteCommand, h, "MRMediaRemoteSendCommand")

	dh, err := purego.Dlopen("/usr/lib/libSystem.dylib", purego.RTLD_LAZY|purego.RTLD_GLOBAL)
	if err != nil {
		return err
	}
	purego.RegisterLibFunc(&dispatchQueueCreate, dh, "dispatch_queue_create")
	return nil
}

func queue() uintptr {
	label := append([]byte("com.halunhaku.tingyu.spike.np\x00"), 0)
	return dispatchQueueCreate(&label[0], 0)
}

// printState 打一行 JSON：系统认的 pid、是否在播、tile 字典的可读文本。
func printState() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	out := map[string]any{"at": time.Now().Format("15:04:05.000")}

	// pid
	pidCh := make(chan int32, 1)
	bPID := objc.NewBlock(func(_ objc.Block, pid int32) { pidCh <- pid })
	getNowPlayingAppPID(queue(), bPID)
	select {
	case pid := <-pidCh:
		out["nowPlayingPID"] = pid
		out["selfPID"] = os.Getpid()
		out["attributedToUs"] = int(pid) == os.Getpid()
	case <-time.After(3 * time.Second):
		out["nowPlayingPID"] = "timeout"
	}
	bPID.Release()

	// is playing
	playCh := make(chan int8, 1)
	bPlay := objc.NewBlock(func(_ objc.Block, v int8) { playCh <- v })
	getNowPlayingPlaying(queue(), bPlay)
	select {
	case v := <-playCh:
		out["systemIsPlaying"] = v != 0
	case <-time.After(3 * time.Second):
		out["systemIsPlaying"] = "timeout"
	}
	bPlay.Release()

	// info dict
	infoCh := make(chan string, 1)
	bInfo := objc.NewBlock(func(_ objc.Block, dict objc.ID) { infoCh <- describe(dict) })
	getNowPlayingInfo(queue(), bInfo)
	select {
	case d := <-infoCh:
		out["tile"] = d
	case <-time.After(3 * time.Second):
		out["tile"] = "timeout"
	}
	bInfo.Release()

	b, _ := json.Marshal(out)
	fmt.Println(string(b))
}

// describe 把 NSDictionary 的 description 转成一行文本（CFDictionary 与
// NSDictionary 是 toll-free bridged，可以直接当对象发消息）。
func describe(dict objc.ID) string {
	if dict == 0 {
		return "(nil)"
	}
	desc := objc.Send[objc.ID](dict, objc.RegisterName("description"))
	if desc == 0 {
		return "(no description)"
	}
	ptr := objc.Send[unsafe.Pointer](desc, objc.RegisterName("UTF8String"))
	if ptr == nil {
		return "(no utf8)"
	}
	s := goString(ptr)
	if len(s) > 3000 {
		s = s[:3000] + "…"
	}
	return strings.ReplaceAll(s, "\n", " ")
}

// positionInfo 给 MRMediaRemoteSendCommand(kMRSeekToPlaybackPosition) 用：
// userInfo 里要带 kMRMediaRemoteOptionPlaybackPosition（秒，double）。
func positionInfo(keyName string, value float64) objc.ID {
	dict := objc.Send[objc.ID](objc.ID(objc.GetClass("NSMutableDictionary")), objc.RegisterName("alloc"))
	dict = objc.Send[objc.ID](dict, objc.RegisterName("init"))
	var num objc.ID
	if keyName == "kMRMediaRemoteOptionPlaybackPositionMicroseconds" {
		num = objc.Send[objc.ID](objc.ID(objc.GetClass("NSNumber")), objc.RegisterName("numberWithLongLong:"), int64(value))
	} else {
		num = objc.Send[objc.ID](objc.ID(objc.GetClass("NSNumber")), objc.RegisterName("numberWithDouble:"), value)
	}
	key := objc.Send[objc.ID](objc.ID(objc.GetClass("NSString")), objc.RegisterName("stringWithUTF8String:"), cstr(keyName))
	objc.Send[objc.ID](dict, objc.RegisterName("setObject:forKey:"), num, key)
	return dict
}

func commandCode(name string) (int32, bool) {
	switch name {
	case "play":
		return 0, true
	case "pause":
		return 1, true
	case "toggle":
		return 2, true
	case "stop":
		return 3, true
	case "next":
		return 4, true
	case "prev":
		return 5, true
	case "seek", "seekus":
		return 6, true
	}
	return 0, false
}

func cstr(s string) *byte {
	b := append([]byte(s), 0)
	return &b[0]
}

func goString(p unsafe.Pointer) string {
	n := 0
	for *(*byte)(unsafe.Add(p, n)) != 0 {
		n++
		if n > 1<<20 {
			break
		}
	}
	return string(unsafe.Slice((*byte)(p), n))
}
