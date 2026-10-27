package model

import (
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"testing"
)

func TestPlayerVolumeIncludesMute(t *testing.T) {
	s, _ := newTestState(t, tracks(2))
	for _, volume := range []float64{.8, .2, 0, 1} {
		s.SetPlayer(player.Update{Snapshot: mpv.Snapshot{Volume: volume}})
		if s.Volume() != volume {
			t.Fatalf("snapshot %v left volume at %v", volume, s.Volume())
		}
	}
}
