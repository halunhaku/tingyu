package accept

import (
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"time"
)

// Check is one acceptance item: a name, a verdict and the numbers behind it.
// Data is what the M2 record quotes, so it holds measured values, never a
// restatement of the code.
type Check struct {
	ID      string         `json:"id"`
	Name    string         `json:"name"`
	Pass    bool           `json:"pass"`
	Skipped bool           `json:"skipped,omitempty"`
	Note    string         `json:"note,omitempty"`
	Data    map[string]any `json:"data,omitempty"`
}

// Report is the whole run.
type Report struct {
	StartedAt  time.Time `json:"startedAt"`
	FinishedAt time.Time `json:"finishedAt"`
	Host       Host      `json:"host"`
	MediaDir   string    `json:"mediaDir"`
	Checks     []Check   `json:"checks"`
}

// Host records what the numbers were measured on.
type Host struct {
	OS         string `json:"os"`
	Arch       string `json:"arch"`
	GoVersion  string `json:"goVersion"`
	MPVPath    string `json:"mpvPath"`
	MPVAPI     string `json:"mpvClientAPI"`
	AudioValue string `json:"audioOutput"`
}

// Add appends a check.
func (r *Report) Add(check Check) {
	r.Checks = append(r.Checks, check)
}

// Pass counts passing checks.
func (r *Report) Pass() int {
	count := 0
	for _, check := range r.Checks {
		if check.Pass && !check.Skipped {
			count++
		}
	}
	return count
}

// Failed lists the IDs that failed.
func (r *Report) Failed() []string {
	var ids []string
	for _, check := range r.Checks {
		if !check.Pass && !check.Skipped {
			ids = append(ids, check.ID)
		}
	}
	return ids
}

// Write stores the report as JSON and prints a one-line summary per check.
func (r *Report) Write(outDir string) (string, error) {
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return "", err
	}
	path := outDir + "/report.json"
	raw, err := json.MarshalIndent(r, "", " ")
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(path, append(raw, '\n'), 0o644); err != nil {
		return "", err
	}
	return path, nil
}

// Summary renders one line per check for the console.
func (r *Report) Summary() string {
	out := ""
	for _, check := range r.Checks {
		verdict := "PASS"
		if check.Skipped {
			verdict = "SKIP"
		} else if !check.Pass {
			verdict = "FAIL"
		}
		out += fmt.Sprintf("%s  %-28s %s\n", verdict, check.ID, check.Name)
	}
	out += fmt.Sprintf("%d/%d passed", r.Pass(), len(r.Checks))
	if failed := r.Failed(); len(failed) > 0 {
		out += fmt.Sprintf(", failed: %v", failed)
	}
	return out
}

// hostInfo collects the host fields.
func hostInfo(mpvPath, api, audio string) Host {
	return Host{OS: runtime.GOOS, Arch: runtime.GOARCH, GoVersion: runtime.Version(), MPVPath: mpvPath, MPVAPI: api, AudioValue: audio}
}
