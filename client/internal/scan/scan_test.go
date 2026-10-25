package scan

import (
	"encoding/binary"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// --- builders ---------------------------------------------------------

func flacFile(t *testing.T, path string) {
	t.Helper()
	const sampleRate = 96000
	const seconds = 2
	streamInfo := make([]byte, 34)
	binary.BigEndian.PutUint16(streamInfo[0:2], 4096)
	binary.BigEndian.PutUint16(streamInfo[2:4], 4096)
	packed := uint64(sampleRate)<<44 | uint64(1)<<41 | uint64(23)<<36 | uint64(sampleRate*seconds)
	binary.BigEndian.PutUint64(streamInfo[10:18], packed)

	var comment strings.Builder
	binary.Write(&comment, binary.LittleEndian, uint32(4))
	comment.WriteString("test")
	entries := []string{
		"TITLE=海湾 测试", "ARTIST=歌手甲", "ALBUM=专辑乙", "TRACKNUMBER=3/12",
		"DATE=2021-04-05", "GENRE=Ambient",
	}
	binary.Write(&comment, binary.LittleEndian, uint32(len(entries)))
	for _, entry := range entries {
		binary.Write(&comment, binary.LittleEndian, uint32(len(entry)))
		comment.WriteString(entry)
	}

	picture := make([]byte, 0, 64)
	picture = binary.BigEndian.AppendUint32(picture, 3)
	picture = binary.BigEndian.AppendUint32(picture, 9)
	picture = append(picture, "image/png"...)
	picture = binary.BigEndian.AppendUint32(picture, 0)
	picture = binary.BigEndian.AppendUint32(picture, 512)
	picture = binary.BigEndian.AppendUint32(picture, 512)
	picture = binary.BigEndian.AppendUint32(picture, 24)
	picture = binary.BigEndian.AppendUint32(picture, 0)
	png := []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4}
	picture = binary.BigEndian.AppendUint32(picture, uint32(len(png)))
	picture = append(picture, png...)

	var out []byte
	out = append(out, "fLaC"...)
	out = append(out, metaBlock(0, streamInfo, false)...)
	out = append(out, metaBlock(4, []byte(comment.String()), false)...)
	out = append(out, metaBlock(6, picture, true)...)
	if err := os.WriteFile(path, out, 0o644); err != nil {
		t.Fatal(err)
	}
}

func metaBlock(blockType byte, body []byte, last bool) []byte {
	head := byte(blockType)
	if last {
		head |= 0x80
	}
	out := []byte{head, byte(len(body) >> 16), byte(len(body) >> 8), byte(len(body))}
	return append(out, body...)
}

func wavFile(t *testing.T, path string) {
	t.Helper()
	const sampleRate = 44100
	const channels = 2
	const bits = 16
	byteRate := sampleRate * channels * bits / 8
	data := make([]byte, byteRate) // exactly one second
	var fmtChunk []byte
	fmtChunk = binary.LittleEndian.AppendUint16(fmtChunk, 1)
	fmtChunk = binary.LittleEndian.AppendUint16(fmtChunk, channels)
	fmtChunk = binary.LittleEndian.AppendUint32(fmtChunk, sampleRate)
	fmtChunk = binary.LittleEndian.AppendUint32(fmtChunk, uint32(byteRate))
	fmtChunk = binary.LittleEndian.AppendUint16(fmtChunk, channels*bits/8)
	fmtChunk = binary.LittleEndian.AppendUint16(fmtChunk, bits)
	info := append([]byte("INFO"), riffChunk("INAM", []byte("WAV 歌名\x00"))...)
	info = append(info, riffChunk("IART", []byte("WAV 歌手\x00"))...)
	info = append(info, riffChunk("IPRD", []byte("WAV 专辑\x00"))...)
	body := append(riffChunk("fmt ", fmtChunk), riffChunk("data", data)...)
	body = append(body, riffChunk("LIST", info)...)
	out := append([]byte("RIFF\x00\x00\x00\x00WAVE"), body...)
	binary.LittleEndian.PutUint32(out[4:8], uint32(len(out)-8))
	if err := os.WriteFile(path, out, 0o644); err != nil {
		t.Fatal(err)
	}
}

func riffChunk(id string, body []byte) []byte {
	out := append([]byte(id), 0, 0, 0, 0)
	binary.LittleEndian.PutUint32(out[4:8], uint32(len(body)))
	out = append(out, body...)
	if len(body)%2 == 1 {
		out = append(out, 0)
	}
	return out
}

func aiffFile(t *testing.T, path string) {
	t.Helper()
	comm := make([]byte, 18)
	binary.BigEndian.PutUint16(comm[0:2], 2)
	binary.BigEndian.PutUint32(comm[2:6], 44100) // one second
	binary.BigEndian.PutUint16(comm[6:8], 16)
	// 44100 as an 80-bit extended float: exponent 0x400E, mantissa 0xAC44…
	copy(comm[8:18], []byte{0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0})
	body := append(riffBEChunk("COMM", comm), riffBEChunk("NAME", []byte("AIFF 名字"))...)
	out := append([]byte("FORM\x00\x00\x00\x00AIFF"), body...)
	binary.BigEndian.PutUint32(out[4:8], uint32(len(out)-8))
	if err := os.WriteFile(path, out, 0o644); err != nil {
		t.Fatal(err)
	}
}

func riffBEChunk(id string, body []byte) []byte {
	out := append([]byte(id), 0, 0, 0, 0)
	binary.BigEndian.PutUint32(out[4:8], uint32(len(body)))
	out = append(out, body...)
	if len(body)%2 == 1 {
		out = append(out, 0)
	}
	return out
}

func mp3File(t *testing.T, path string) {
	t.Helper()
	frames := 100
	// MPEG1 layer III, 128 kbps, 44100 Hz, stereo: frame size 417 bytes.
	frame := make([]byte, 417)
	copy(frame[0:4], []byte{0xFF, 0xFB, 0x90, 0x00})
	// Xing header after 32 bytes of side information (stereo, MPEG1).
	copy(frame[36:40], "Xing")
	binary.BigEndian.PutUint32(frame[40:44], 1) // frames field present
	binary.BigEndian.PutUint32(frame[44:48], uint32(frames))

	var framesBody []byte
	add := func(id string, body []byte) {
		head := make([]byte, 10)
		copy(head, id)
		binary.BigEndian.PutUint32(head[4:8], uint32(len(body)))
		framesBody = append(framesBody, head...)
		framesBody = append(framesBody, body...)
	}
	add("TIT2", append([]byte{3}, "MP3 标题"...))
	add("TPE1", append([]byte{3}, "MP3 歌手"...))
	add("TALB", append([]byte{3}, "MP3 专辑"...))
	add("TRCK", append([]byte{0}, "7/9"...))
	add("TYER", append([]byte{0}, "2019"...))

	header := []byte{'I', 'D', '3', 3, 0, 0, 0, 0, 0, 0}
	size := len(framesBody)
	header[6] = byte(size >> 21 & 0x7f)
	header[7] = byte(size >> 14 & 0x7f)
	header[8] = byte(size >> 7 & 0x7f)
	header[9] = byte(size & 0x7f)
	out := append(header, framesBody...)
	out = append(out, frame...)
	if err := os.WriteFile(path, out, 0o644); err != nil {
		t.Fatal(err)
	}
}

func mp4File(t *testing.T, path string) {
	t.Helper()
	mvhd := make([]byte, 20)
	binary.BigEndian.PutUint32(mvhd[12:16], 44100)
	binary.BigEndian.PutUint32(mvhd[16:20], 88200) // two seconds

	dataBox := func(value []byte, flags uint32) []byte {
		body := make([]byte, 8)
		binary.BigEndian.PutUint32(body[0:4], flags)
		return box("data", append(body, value...))
	}
	trkn := []byte{0, 0, 0, 5, 0, 12}
	ilst := append(box("\xa9nam", dataBox([]byte("MP4 标题"), 1)),
		box("\xa9ART", dataBox([]byte("MP4 歌手"), 1))...)
	ilst = append(ilst, box("\xa9alb", dataBox([]byte("MP4 专辑"), 1))...)
	ilst = append(ilst, box("trkn", dataBox(trkn, 0))...)
	ilst = append(ilst, box("covr", dataBox([]byte{0x89, 'P', 'N', 'G', 1}, 13))...)
	meta := append(make([]byte, 4), box("ilst", ilst)...)
	udta := box("udta", box("meta", meta))
	moov := box("moov", append(box("mvhd", mvhd), udta...))
	out := append(box("ftyp", []byte("M4A \x00\x00\x00\x00")), moov...)
	if err := os.WriteFile(path, out, 0o644); err != nil {
		t.Fatal(err)
	}
}

func box(typ string, body []byte) []byte {
	out := make([]byte, 8)
	binary.BigEndian.PutUint32(out[0:4], uint32(len(body)+8))
	copy(out[4:8], typ)
	return append(out, body...)
}

func aacFile(t *testing.T, path string) {
	t.Helper()
	const frames = 10
	const frameLength = 8
	var out []byte
	for range frames {
		head := make([]byte, 7)
		head[0] = 0xFF
		head[1] = 0xF1
		head[2] = 1<<6 | 4<<2 // AAC LC, 44100
		head[3] = 2 << 6      // channel config 2 high bits
		head[3] |= byte(frameLength >> 11 & 0x03)
		head[4] = byte(frameLength >> 3)
		head[5] = byte(frameLength&0x07)<<5 | 0x1F
		head[6] = 0xFC
		out = append(out, head...)
		out = append(out, 0)
	}
	if err := os.WriteFile(path, out, 0o644); err != nil {
		t.Fatal(err)
	}
}

func oggFile(t *testing.T, path string) {
	t.Helper()
	id := make([]byte, 30)
	copy(id, "\x01vorbis")
	binary.LittleEndian.PutUint32(id[7:11], 0)
	id[11] = 2
	binary.LittleEndian.PutUint32(id[12:16], 44100)
	comment := append([]byte("\x03vorbis"), vorbisCommentBody([]string{"TITLE=OGG 标题", "ARTIST=OGG 歌手"})...)
	page := oggPageBytes(2, 0, 1, 0, [][]byte{id, comment})
	last := oggPageBytes(4, 88200, 1, 1, nil)
	out := append(page, last...)
	if err := os.WriteFile(path, out, 0o644); err != nil {
		t.Fatal(err)
	}
}

func vorbisCommentBody(entries []string) []byte {
	var b []byte
	b = binary.LittleEndian.AppendUint32(b, 4)
	b = append(b, "test"...)
	b = binary.LittleEndian.AppendUint32(b, uint32(len(entries)))
	for _, entry := range entries {
		b = binary.LittleEndian.AppendUint32(b, uint32(len(entry)))
		b = append(b, entry...)
	}
	return b
}

func oggPageBytes(headerType byte, granule int64, serial, sequence uint32, packets [][]byte) []byte {
	var payload []byte
	var lacing []byte
	for _, packet := range packets {
		remaining := len(packet)
		for remaining >= 255 {
			lacing = append(lacing, 255)
			remaining -= 255
		}
		lacing = append(lacing, byte(remaining))
		payload = append(payload, packet...)
	}
	head := make([]byte, 27)
	copy(head, "OggS")
	head[4] = 0
	head[5] = headerType
	binary.LittleEndian.PutUint64(head[6:14], uint64(granule))
	binary.LittleEndian.PutUint32(head[14:18], serial)
	binary.LittleEndian.PutUint32(head[18:22], sequence)
	head[26] = byte(len(lacing))
	return append(append(head, lacing...), payload...)
}

// --- tests ------------------------------------------------------------

func TestReadFLAC(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tone.flac")
	flacFile(t, path)
	meta, err := ReadMeta(path)
	if err != nil {
		t.Fatal(err)
	}
	if meta.Title != "海湾 测试" || meta.Artist != "歌手甲" || meta.Album != "专辑乙" {
		t.Errorf("tags = %+v", meta)
	}
	if meta.SampleRate != 96000 || meta.Duration != 2*time.Second {
		t.Errorf("sample rate %d duration %v", meta.SampleRate, meta.Duration)
	}
	if meta.TrackNumber != 3 || meta.Year != 2021 || meta.Genre != "Ambient" {
		t.Errorf("numbers = %+v", meta)
	}
	if len(meta.Picture) == 0 || CoverName(meta.Picture)[16:] != ".png" {
		t.Errorf("picture = %d bytes, name %q", len(meta.Picture), CoverName(meta.Picture))
	}
}

func TestReadWAV(t *testing.T) {
	path := filepath.Join(t.TempDir(), "song.wav")
	wavFile(t, path)
	meta, err := ReadMeta(path)
	if err != nil {
		t.Fatal(err)
	}
	if meta.Duration != time.Second || meta.SampleRate != 44100 {
		t.Errorf("duration %v sample rate %d", meta.Duration, meta.SampleRate)
	}
	if meta.Title != "WAV 歌名" || meta.Artist != "WAV 歌手" || meta.Album != "WAV 专辑" {
		t.Errorf("tags = %+v", meta)
	}
}

func TestReadAIFF(t *testing.T) {
	path := filepath.Join(t.TempDir(), "song.aiff")
	aiffFile(t, path)
	meta, err := ReadMeta(path)
	if err != nil {
		t.Fatal(err)
	}
	if meta.SampleRate != 44100 || meta.Duration != time.Second {
		t.Errorf("rate %d duration %v", meta.SampleRate, meta.Duration)
	}
	if meta.Title != "AIFF 名字" {
		t.Errorf("title = %q", meta.Title)
	}
}

func TestReadMP3(t *testing.T) {
	path := filepath.Join(t.TempDir(), "song.mp3")
	mp3File(t, path)
	meta, err := ReadMeta(path)
	if err != nil {
		t.Fatal(err)
	}
	if meta.Title != "MP3 标题" || meta.Artist != "MP3 歌手" || meta.Album != "MP3 专辑" {
		t.Errorf("tags = %+v", meta)
	}
	if meta.TrackNumber != 7 || meta.Year != 2019 {
		t.Errorf("numbers = %+v", meta)
	}
	want := durationFromFrames(100, 1152, 44100)
	if meta.Duration != want || meta.Bitrate != 128 {
		t.Errorf("duration %v (want %v) bitrate %d", meta.Duration, want, meta.Bitrate)
	}
}

func TestReadMP4(t *testing.T) {
	path := filepath.Join(t.TempDir(), "song.m4a")
	mp4File(t, path)
	meta, err := ReadMeta(path)
	if err != nil {
		t.Fatal(err)
	}
	if meta.Title != "MP4 标题" || meta.Artist != "MP4 歌手" || meta.Album != "MP4 专辑" {
		t.Errorf("tags = %+v", meta)
	}
	if meta.TrackNumber != 5 || meta.Duration != 2*time.Second {
		t.Errorf("track %d duration %v", meta.TrackNumber, meta.Duration)
	}
	if len(meta.Picture) == 0 {
		t.Error("cover not extracted")
	}
}

func TestReadAAC(t *testing.T) {
	path := filepath.Join(t.TempDir(), "song.aac")
	aacFile(t, path)
	meta, err := ReadMeta(path)
	if err != nil {
		t.Fatal(err)
	}
	if meta.SampleRate != 44100 {
		t.Errorf("sample rate = %d", meta.SampleRate)
	}
	want := durationFromFrames(10, 1024, 44100)
	if meta.Duration != want {
		t.Errorf("duration = %v, want %v", meta.Duration, want)
	}
}

func TestReadOgg(t *testing.T) {
	path := filepath.Join(t.TempDir(), "song.ogg")
	oggFile(t, path)
	meta, err := ReadMeta(path)
	if err != nil {
		t.Fatal(err)
	}
	if meta.SampleRate != 44100 || meta.Duration != 2*time.Second {
		t.Errorf("rate %d duration %v", meta.SampleRate, meta.Duration)
	}
	if meta.Title != "OGG 标题" || meta.Artist != "OGG 歌手" {
		t.Errorf("tags = %+v", meta)
	}
}

func TestCoverNameIsContentAddressed(t *testing.T) {
	png := []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}
	jpg := []byte{0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3}
	if a, b := CoverName(png), CoverName(append([]byte(nil), png...)); a != b {
		t.Fatalf("same bytes, different names: %q vs %q", a, b)
	}
	if CoverName(png) == CoverName(jpg) {
		t.Fatal("different bytes, same name")
	}
	if got := CoverName(png); !strings.HasSuffix(got, ".png") || len(got) != 20 {
		t.Fatalf("name = %q (%d chars)", got, len(got))
	}
	if strings.HasPrefix(CoverName([]byte{0xFF, 0xD8}), "-") {
		t.Fatal("negative hex leaked into a filename")
	}

	dir := t.TempDir()
	name, err := SaveCover(dir, jpg)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(dir, name))
	if err != nil || info.Size() != int64(len(jpg)) {
		t.Fatalf("cover not written: %v", err)
	}
	// Same bytes: no rewrite (mtime unchanged).
	before, _ := os.Stat(filepath.Join(dir, name))
	time.Sleep(2 * time.Millisecond)
	if _, err := SaveCover(dir, jpg); err != nil {
		t.Fatal(err)
	}
	after, _ := os.Stat(filepath.Join(dir, name))
	if !before.ModTime().Equal(after.ModTime()) {
		t.Error("SaveCover rewrote an identical cover")
	}
}

func TestScanWalksHiddenAndUnsupportedFiles(t *testing.T) {
	root := filepath.Join(t.TempDir(), "听屿 测试 音乐")
	if err := os.MkdirAll(filepath.Join(root, "子目录", ".hidden"), 0o755); err != nil {
		t.Fatal(err)
	}
	wavFile(t, filepath.Join(root, "一首.wav"))
	flacFile(t, filepath.Join(root, "子目录", "两首.FLAC"))
	if err := os.WriteFile(filepath.Join(root, "说明.txt"), []byte("no"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".隐藏.wav"), []byte("no"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "子目录", ".hidden", "藏起来.wav"), []byte("no"), 0o644); err != nil {
		t.Fatal(err)
	}

	var progress []string
	result := Scan(root, Options{
		CoversDir: filepath.Join(t.TempDir(), "covers"),
		Progress:  func(done, total int, path string) { progress = append(progress, path) },
	})
	if result.Files != 2 || len(result.Tracks) != 2 {
		t.Fatalf("files=%d tracks=%d (%+v)", result.Files, len(result.Tracks), result.Tracks)
	}
	if !result.Authoritative() {
		t.Errorf("clean scan not authoritative: %+v", result)
	}
	if len(progress) != 2 {
		t.Errorf("progress calls = %d", len(progress))
	}
	// Sorted: 子目录/两首.FLAC sorts after 一首.wav in byte order.
	if !strings.HasSuffix(result.Tracks[0].FilePathOrURL, "一首.wav") {
		t.Errorf("first track = %s", result.Tracks[0].FilePathOrURL)
	}
	if result.Tracks[0].Title != "WAV 歌名" {
		t.Errorf("title = %q, want the WAV tag", result.Tracks[0].Title)
	}
	if result.Tracks[1].CoverArtPath == "" {
		t.Error("FLAC cover was not stored")
	}
	if info, err := os.Stat(filepath.Join(result.Tracks[1].FilePathOrURL)); err != nil || info.Size() == 0 {
		t.Fatal("fixture vanished")
	}
}

func TestScanKnownFactsSkipParsing(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "tagged.flac")
	flacFile(t, path)
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	known := library.FileFacts{
		path: {Size: info.Size(), Modified: info.ModTime().Truncate(time.Microsecond)},
	}
	result := Scan(root, Options{Known: known})
	if len(result.Tracks) != 1 {
		t.Fatalf("tracks = %+v", result.Tracks)
	}
	track := result.Tracks[0]
	if track.Title != "tagged" || track.Duration != 0 {
		t.Errorf("unchanged file was parsed again: %+v", track)
	}
	if track.FileSize != info.Size() || track.LastModified.IsZero() {
		t.Errorf("file facts = %+v", track)
	}
}

func TestScanCancellationAndTruncationAreNotAuthoritative(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"a.wav", "b.wav", "c.wav"} {
		wavFile(t, filepath.Join(root, name))
	}
	cancelled := Scan(root, Options{Cancelled: func() bool { return true }})
	if !cancelled.Cancelled || cancelled.Authoritative() {
		t.Errorf("cancelled = %+v", cancelled)
	}
	truncated := Scan(root, Options{MaxFiles: 2})
	if !truncated.Truncated || truncated.Files != 2 || truncated.Authoritative() {
		t.Errorf("truncated = %+v", truncated)
	}
	missing := Scan(filepath.Join(root, "nope"), Options{})
	if missing.UnreadableDirs != 1 || missing.Authoritative() {
		t.Errorf("missing root = %+v", missing)
	}
}

func TestExtended80(t *testing.T) {
	rate := extended80([]byte{0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0})
	if math.Abs(rate-44100) > 0.001 {
		t.Fatalf("extended80 = %v, want 44100", rate)
	}
}
