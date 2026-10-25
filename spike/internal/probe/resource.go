package probe

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Sample is one process resource measurement.
type Sample struct {
	At         time.Time `json:"at"`
	RSSMB      float64   `json:"rss_mb"`
	CPUPercent float64   `json:"cpu_percent"`
}

// SampleSelf measures the current process with ps(1). RSS is reported by ps
// in kilobytes, so it is scaled to MiB. %cpu is ps's own utilization figure
// (a decayed average over recent CPU time), not an instantaneous value.
func SampleSelf() (Sample, error) {
	ps := exec.Command("ps", "-o", "rss=", "-o", "%cpu=", "-p", strconv.Itoa(os.Getpid()))
	// ps formats numbers with the process locale; force the C locale so
	// ParseFloat never sees a decimal comma.
	ps.Env = append(os.Environ(), "LC_ALL=C")
	out, err := ps.Output()
	if err != nil {
		return Sample{}, fmt.Errorf("probe: ps: %w", err)
	}
	fields := strings.Fields(string(out))
	if len(fields) != 2 {
		return Sample{}, fmt.Errorf("probe: unexpected ps output %q", strings.TrimSpace(string(out)))
	}
	rssKB, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return Sample{}, fmt.Errorf("probe: parse ps rss %q: %w", fields[0], err)
	}
	cpuPercent, err := strconv.ParseFloat(fields[1], 64)
	if err != nil {
		return Sample{}, fmt.Errorf("probe: parse ps %%cpu %q: %w", fields[1], err)
	}
	return Sample{At: time.Now(), RSSMB: rssKB / 1024, CPUPercent: cpuPercent}, nil
}

// Sampler writes one JSON object per line to w: immediately, then every
// interval, until stop is closed. Write and sample errors are dropped because
// the signature has nowhere to report them; a failed sample simply produces
// no line. Sampler blocks until stop is closed and must be called from a
// single goroutine.
func Sampler(interval time.Duration, w io.Writer, stop <-chan struct{}) {
	if interval <= 0 {
		interval = time.Second
	}
	encoder := json.NewEncoder(w)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		if sample, err := SampleSelf(); err == nil {
			_ = encoder.Encode(sample)
		}
		select {
		case <-stop:
			return
		case <-ticker.C:
		}
	}
}
