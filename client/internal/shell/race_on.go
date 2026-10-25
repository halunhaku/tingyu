//go:build race

package shell

// raceEnabled reports that the race detector instruments this build. The
// frame-time gate is measured without -race, where its instrumentation would
// dominate the measurement; the scroll test skips itself so `go test -race`
// still covers every functional path.
const raceEnabled = true
