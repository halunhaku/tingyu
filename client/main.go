// Command tingyu is the M0 skeleton of the Tingyu macOS client: a native
// MyGo window listing the real library read-only. Playback, scanning and
// media keys arrive in M1 (plan §6).
package main

import (
	"log"

	"github.com/halunhaku/tingyu/client/internal/app"
)

func main() {
	log.SetFlags(0)
	if err := app.Main(); err != nil {
		log.Fatal("tingyu: ", err)
	}
}
