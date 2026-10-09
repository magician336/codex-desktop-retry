package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestUpstreamIdleTimeoutInterruptsBlockedRead(t *testing.T) {
	r, w := io.Pipe()
	defer w.Close()
	body := newUpstreamIdleTimeoutBody(context.Background(), r, 25*time.Millisecond)
	defer body.Close()
	done := make(chan error, 1)
	go func() {
		_, err := body.Read(make([]byte, 1))
		done <- err
	}()
	select {
	case err := <-done:
		var timeout net.Error
		if !errors.Is(err, errUpstreamIdleTimeout) || !errors.Is(err, context.DeadlineExceeded) || !errors.As(err, &timeout) || !timeout.Timeout() {
			t.Fatalf("idle failure cannot be classified as a retryable timeout: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("idle timeout did not interrupt Read")
	}
	if _, err := body.Read(make([]byte, 1)); !errors.Is(err, errUpstreamIdleTimeout) {
		t.Fatalf("subsequent read lost timeout cause: %v", err)
	}
}

func TestUpstreamIdleTimeoutCanBeRetriedByProxy(t *testing.T) {
	var attempts atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if attempts.Add(1) == 1 {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			if flusher, ok := w.(http.Flusher); ok {
				flusher.Flush()
			}
			// Headers have arrived, but no body byte follows before the idle
			// deadline. The relay must discard this attempt and retry it.
			time.Sleep(100 * time.Millisecond)
			return
		}
		_, _ = io.WriteString(w, `{"ok":true}`)
	}))
	defer upstream.Close()

	parsed, err := url.Parse(upstream.URL + "/v1")
	if err != nil {
		t.Fatal(err)
	}
	proxy := &proxy{
		cfg:    config{upstream: parsed, maxRetries: 1, backoff: 0, maxRetryWait: time.Second, idleTimeout: 20 * time.Millisecond},
		client: upstream.Client(),
	}
	server := httptest.NewServer(proxy)
	defer server.Close()

	resp, err := http.Get(server.URL + "/v1/responses")
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	if got := attempts.Load(); got != 2 {
		t.Fatalf("upstream attempts=%d, want 2", got)
	}
	if resp.StatusCode != http.StatusOK || string(body) != `{"ok":true}` {
		t.Fatalf("status=%d body=%q", resp.StatusCode, body)
	}
}

func TestUpstreamIdleTimeoutDoesNotLimitStreamLifetime(t *testing.T) {
	r, w := io.Pipe()
	body := newUpstreamIdleTimeoutBody(context.Background(), r, 150*time.Millisecond)
	defer body.Close()
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		defer w.Close()
		ticker := time.NewTicker(15 * time.Millisecond)
		defer ticker.Stop()
		for i := 0; i < 24; i++ {
			<-ticker.C
			if _, err := w.Write([]byte("x")); err != nil {
				return
			}
		}
	}()
	started := time.Now()
	got, err := io.ReadAll(body)
	if err != nil || string(got) != strings.Repeat("x", 24) {
		t.Fatalf("healthy stream interrupted: body=%q err=%v", got, err)
	}
	if time.Since(started) <= 150*time.Millisecond {
		t.Fatal("test did not exercise a stream longer than the idle timeout")
	}
	<-writerDone
}

type closeUnblocksTestBody struct {
	readStarted chan struct{}
	closed      chan struct{}
	startOnce   sync.Once
	closeOnce   sync.Once
	closeCount  atomic.Int32
}

func (b *closeUnblocksTestBody) Read([]byte) (int, error) {
	b.startOnce.Do(func() { close(b.readStarted) })
	<-b.closed
	return 0, io.ErrClosedPipe
}

func (b *closeUnblocksTestBody) Close() error {
	b.closeCount.Add(1)
	b.closeOnce.Do(func() { close(b.closed) })
	return nil
}

func TestUpstreamIdleTimeoutCloseAndCancellationUnblockRead(t *testing.T) {
	for _, mode := range []string{"close", "cancel", "concurrent"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			source := &closeUnblocksTestBody{readStarted: make(chan struct{}), closed: make(chan struct{})}
			body := newUpstreamIdleTimeoutBody(ctx, source, time.Hour)
			defer body.Close()
			done := make(chan error, 1)
			go func() {
				_, err := body.Read(make([]byte, 1))
				done <- err
			}()
			<-source.readStarted
			var closers sync.WaitGroup
			switch mode {
			case "cancel":
				cancel()
			case "close":
				_ = body.Close()
			case "concurrent":
				for i := 0; i < 16; i++ {
					closers.Add(1)
					go func() {
						defer closers.Done()
						cancel()
						_ = body.Close()
					}()
				}
			}
			select {
			case err := <-done:
				if mode == "cancel" && !errors.Is(err, context.Canceled) {
					t.Fatalf("lost cancellation cause: %v", err)
				}
				if err == nil || errors.Is(err, errUpstreamIdleTimeout) {
					t.Fatalf("unexpected close/cancellation result: %v", err)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("Read goroutine remained blocked after close/cancellation")
			}
			closers.Wait()
			_ = body.Close()
			if got := source.closeCount.Load(); got != 1 {
				t.Fatalf("underlying Close called %d times, want 1", got)
			}
		})
	}
}

func TestUpstreamIdleTimeoutStaleCallbackCannotCloseNextRead(t *testing.T) {
	source := &closeUnblocksTestBody{readStarted: make(chan struct{}), closed: make(chan struct{})}
	body := newUpstreamIdleTimeoutBody(context.Background(), source, time.Hour).(*upstreamIdleTimeoutBody)
	defer body.Close()
	// Exercise the generation guard directly without relying on timer scheduling.
	body.mu.Lock()
	body.generation = 2
	body.mu.Unlock()
	body.fail(&upstreamIdleTimeoutError{timeout: time.Hour}, 1, true)
	if got := source.closeCount.Load(); got != 0 {
		t.Fatalf("stale read timer closed the next read: close count=%d", got)
	}
}
