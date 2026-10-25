package probe

import (
	"bytes"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// micFFmpegPath is the Homebrew ffmpeg used for loopback capture. It is a
// literal path rather than a PATH lookup so a failure names the binary that
// was actually tried.
const micFFmpegPath = "/opt/homebrew/bin/ffmpeg"

// RecordMic records from the default microphone for seconds into outPath
// using avfoundation device ":0". rate defaults to 48000 when non-positive.
// The error is the ffmpeg failure with its stderr verbatim, so a TCC
// permission denial ("Input/output error" plus the AVFoundation permission
// message) survives to the caller instead of being flattened.
//
// Recording raises a system microphone permission prompt on first use; the
// verification harness must not call this unattended.
func RecordMic(seconds int, rate int, outPath string) error {
	if seconds <= 0 {
		return fmt.Errorf("probe: RecordMic: seconds must be positive, got %d", seconds)
	}
	if rate <= 0 {
		rate = 48000
	}
	if outPath == "" {
		return fmt.Errorf("probe: RecordMic: empty output path")
	}

	args := []string{
		"-hide_banner",
		"-f", "avfoundation",
		"-i", ":0",
		"-t", strconv.Itoa(seconds),
		"-ac", "1",
		"-ar", strconv.Itoa(rate),
		"-y", outPath,
	}
	cmd := exec.Command(micFFmpegPath, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	cmd.Stdout = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("probe: RecordMic: %s %s: %w: %s",
			micFFmpegPath, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return nil
}
