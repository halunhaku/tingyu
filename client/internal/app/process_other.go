//go:build !darwin

package app

import "time"

// processStart reports false where the process start time is not read; the
// cold-start marks then count from main, and say so.
func processStart() (time.Time, bool) { return time.Time{}, false }
