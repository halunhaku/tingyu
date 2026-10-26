package model

import "time"

// Scrubber turns one progress slider interaction into at most one seek.
//
// The old transport seeked every time the slider's value changed, which on a
// drag is every frame: each seek tears down the decoder and, on a remote
// source (a Quark direct link or WebDAV), sends another HTTP Range request.
// The slider already keeps its value local while it is held (the view only
// copies the playback position back when the drag ends), so the honest rule
// is the one the references implement (research report §3.2): the drag changes
// the display, and the release seeks once.
//
// A slider also takes keyboard focus, where the arrows change the value with
// no press at all; that still seeks, so scrubbing without a pointer keeps
// working.
type Scrubber struct {
	dragging bool
	moved    bool
}

// Seek reports the position to seek to after the slider handled the frame, and
// whether to seek at all. value and end are seconds, end being the slider's
// maximum (the track's duration); pressed is Slider.Pressed() and changed its
// Changed(), read after the slider.
func (s *Scrubber) Seek(value, end float64, pressed, changed bool) (time.Duration, bool) {
	if pressed {
		s.dragging = true
		if changed {
			s.moved = true
		}
		return 0, false
	}
	if s.dragging {
		s.dragging = false
		moved := s.moved
		s.moved = false
		if !moved {
			// A click on the knob that moved nothing needs no seek.
			return 0, false
		}
		return clampSeek(value, end), true
	}
	if changed {
		return clampSeek(value, end), true
	}
	return 0, false
}

// clampSeek keeps the target one second short of the end: seeking to the very
// end reads as "finished" and skips to the next track (research report §3.2).
func clampSeek(value, end float64) time.Duration {
	if end > 1 && value > end-1 {
		value = end - 1
	}
	if value < 0 {
		value = 0
	}
	return time.Duration(value * float64(time.Second))
}
