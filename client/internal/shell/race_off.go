//go:build !race

package shell

// raceEnabled is false in a normal build; see race_on.go.
const raceEnabled = false
