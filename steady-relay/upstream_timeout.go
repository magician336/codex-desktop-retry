package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"
)

var errUpstreamIdleTimeout = errors.New("upstream response read idle timeout")

type upstreamIdleTimeoutError struct {
	timeout time.Duration
}

func (e *upstreamIdleTimeoutError) Error() string {
	return fmt.Sprintf("%s after %s without response data", errUpstreamIdleTimeout, e.timeout)
}

func (e *upstreamIdleTimeoutError) Timeout() bool   { return true }
func (e *upstreamIdleTimeoutError) Temporary() bool { return true }
func (e *upstreamIdleTimeoutError) Is(target error) bool {
	return target == errUpstreamIdleTimeout || target == context.DeadlineExceeded
}

// newUpstreamIdleTimeoutBody bounds each blocking upstream Read, not the total
// lifetime of a response. A stream that keeps producing bytes can run for any
// duration. A non-positive timeout disables the idle timer but still observes
// context cancellation.
//
// As with an http.Response.Body, the underlying body must allow Close concurrent
// with Read and must unblock Read when closed. No reader goroutine is created;
// the timer/cancellation callback closes the body to interrupt a blocked read.
// Callers must close the returned body to release its context registration.
func newUpstreamIdleTimeoutBody(ctx context.Context, body io.ReadCloser, idleTimeout time.Duration) io.ReadCloser {
	b := &upstreamIdleTimeoutBody{body: body, timeout: idleTimeout}
	b.stopCancel = context.AfterFunc(ctx, func() {
		b.fail(ctx.Err(), 0, false)
	})
	return b
}

type upstreamIdleTimeoutBody struct {
	body       io.ReadCloser
	timeout    time.Duration
	stopCancel func() bool
	closeOnce  sync.Once
	closeErr   error
	readMu     sync.Mutex
	mu         sync.Mutex
	timer      *time.Timer
	generation uint64
	closed     bool
	terminal   error
}

func (b *upstreamIdleTimeoutBody) Read(p []byte) (int, error) {
	// HTTP bodies are read sequentially. Serialize accidental concurrent reads
	// so one call cannot reset or stop another call's deadline.
	b.readMu.Lock()
	defer b.readMu.Unlock()
	b.mu.Lock()
	if b.terminal != nil {
		err := b.terminal
		b.mu.Unlock()
		return 0, err
	}
	if b.closed {
		b.mu.Unlock()
		return 0, io.ErrClosedPipe
	}
	b.generation++
	generation := b.generation
	if b.timeout > 0 {
		b.timer = time.AfterFunc(b.timeout, func() {
			b.fail(&upstreamIdleTimeoutError{timeout: b.timeout}, generation, true)
		})
	}
	b.mu.Unlock()

	n, err := b.body.Read(p)
	b.mu.Lock()
	// Invalidate even an already-scheduled timer callback before permitting the
	// next Read, so a stale callback cannot terminate a healthy stream.
	b.generation++
	if b.timer != nil {
		b.timer.Stop()
		b.timer = nil
	}
	if b.terminal != nil {
		err = b.terminal
	}
	b.mu.Unlock()
	return n, err
}

func (b *upstreamIdleTimeoutBody) fail(err error, generation uint64, fromTimer bool) {
	b.mu.Lock()
	if b.closed || (fromTimer && b.generation != generation) {
		b.mu.Unlock()
		return
	}
	b.closed = true
	b.terminal = err
	b.generation++
	if b.timer != nil {
		b.timer.Stop()
		b.timer = nil
	}
	b.mu.Unlock()
	_ = b.closeBody()
}

func (b *upstreamIdleTimeoutBody) Close() error {
	b.mu.Lock()
	b.closed = true
	b.generation++
	if b.timer != nil {
		b.timer.Stop()
		b.timer = nil
	}
	b.mu.Unlock()
	b.stopCancel()
	return b.closeBody()
}

func (b *upstreamIdleTimeoutBody) closeBody() error {
	b.closeOnce.Do(func() { b.closeErr = b.body.Close() })
	return b.closeErr
}
