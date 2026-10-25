package app

import (
	"log"
	"os"
	"time"
)

// startup records the moments that make up a cold start. The plan measures
// cold start as the time from process start to the window being
// interactive (plan §6.1 rule 1), so the earliest mark is the process's
// own start time from the kernel, not main's first statement.
type startup struct {
	process time.Time // zero when the platform cannot report it
	main    time.Time
	logger  *log.Logger
	file    *os.File
}

// newStartup marks main and resolves the process start time. Set
// TINGYU_STARTUP_LOG to also append the marks to a file, which a
// double-clicked .app needs since its stderr goes nowhere.
func newStartup() *startup {
	now := time.Now()
	s := &startup{main: now, logger: log.New(os.Stderr, "", 0)}
	if path := os.Getenv("TINGYU_STARTUP_LOG"); path != "" {
		file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			s.logger.Printf("startup: cannot open %s: %v", path, err)
		} else {
			s.file = file
			s.logger.SetOutput(file)
		}
	}
	if start, ok := processStart(); ok {
		s.process = start
	}
	return s
}

// mark logs how long label took, from process start (when known) and from
// main.
func (s *startup) mark(label string) {
	now := time.Now()
	sinceMain := now.Sub(s.main)
	if s.process.IsZero() {
		s.logger.Printf("startup %-14s %8.1fms since main (process start unavailable)", label, float64(sinceMain)/float64(time.Millisecond))
		return
	}
	sinceProcess := now.Sub(s.process)
	s.logger.Printf("startup %-14s %8.1fms since process, %7.1fms since main", label, float64(sinceProcess)/float64(time.Millisecond), float64(sinceMain)/float64(time.Millisecond))
}

func (s *startup) printf(format string, args ...any) {
	s.logger.Printf(format, args...)
}

// Close flushes and closes TINGYU_STARTUP_LOG, when set.
func (s *startup) Close() error {
	if s.file == nil {
		return nil
	}
	return s.file.Close()
}
