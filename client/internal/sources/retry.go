package sources

// Retry is the Flutter client's HttpRetry, ported: exponential backoff with
// jitter for requests that are safe to replay. Source sync failures are almost
// always temporary (Nutstore's flow control, Quark's rate limiting, one home
// broadband blip), and before retries the user's only remedy was to press
// "同步" again (plan §3.5).

import (
	"context"
	"math/rand"
	"time"
)

// Retry configures replay of idempotent requests.
type Retry struct {
	// MaxAttempts counts the first try; 0 means the default (3).
	MaxAttempts int
	// BaseDelay is the first backoff; 0 means the default (400ms).
	BaseDelay time.Duration
	// MaxDelay caps the backoff; 0 means the default (8s).
	MaxDelay time.Duration
}

// DefaultRetry is the Flutter client's default: three attempts, 400ms base,
// 8s cap.
var DefaultRetry = Retry{MaxAttempts: 3, BaseDelay: 400 * time.Millisecond, MaxDelay: 8 * time.Second}

// NoRetry disables replay (tests and cancel-sensitive callers).
var NoRetry = Retry{MaxAttempts: 1}

func (r Retry) attempts() int {
	if r.MaxAttempts <= 0 {
		return 3
	}
	return r.MaxAttempts
}

func (r Retry) base() time.Duration {
	if r.BaseDelay <= 0 {
		return 400 * time.Millisecond
	}
	return r.BaseDelay
}

func (r Retry) cap() time.Duration {
	if r.MaxDelay <= 0 {
		return 8 * time.Second
	}
	return r.MaxDelay
}

// delayFor is base × 2^(attempt-1), capped and jittered ±20 % so several
// sources or tracks backing off together do not retry in the same millisecond.
func (r Retry) delayFor(attempt int) time.Duration {
	raw := r.base()
	for i := 1; i < attempt; i++ {
		raw *= 2
		if raw >= r.cap() {
			raw = r.cap()
			break
		}
	}
	if raw > r.cap() {
		raw = r.cap()
	}
	jitter := 0.8 + rand.Float64()*0.4
	return time.Duration(float64(raw) * jitter)
}

// Do runs fn until it reports no retryable failure, succeeds, or attempts run
// out. fn returns retryable=false when the result must be returned as is (a
// 401, a 404: replaying would fail identically). ctx cancellation returns
// ctx.Err() without another try.
func (r Retry) Do(ctx context.Context, logf func(string, ...any), fn func(attempt int) (retryable bool, err error)) error {
	attempts := r.attempts()
	var err error
	for attempt := 1; attempt <= attempts; attempt++ {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return ctxErr
		}
		retryable, tryErr := fn(attempt)
		err = tryErr
		if tryErr == nil || !retryable || attempt == attempts {
			return tryErr
		}
		delay := r.delayFor(attempt)
		if logf != nil {
			logf("sources: attempt %d/%d failed (%v), retrying in %s", attempt, attempts, tryErr, delay.Round(time.Millisecond))
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
	return err
}

// RetryableStatus reports whether an HTTP status is worth replaying: rate
// limits and server-side failures, never a credential or request error.
func RetryableStatus(status int) bool {
	return status == 429 || status == 503 || status >= 500
}
