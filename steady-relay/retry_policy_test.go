package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const retryPolicyRequestBody = "{\n  \"model\": \"test-model\", \"input\": \"unchanged\"\n}"

// Check each attempt, not only the successful one: retries must preserve the
// exact payload, authentication, caller-supplied idempotency key and URL.
func checkRetryPolicyRequest(t *testing.T, r *http.Request) {
	t.Helper()
	body, err := io.ReadAll(r.Body)
	if err != nil || string(body) != retryPolicyRequestBody {
		t.Errorf("request body changed: %q, error=%v", body, err)
	}
	if r.Method != http.MethodPost || r.URL.RequestURI() != "/v1/responses?trace=a%2Fb" {
		t.Errorf("request changed: method=%s URI=%s", r.Method, r.URL.RequestURI())
	}
	for key, want := range map[string]string{
		"Authorization": "Bearer test-secret", "Idempotency-Key": "caller-owned-key", "X-Custom": "untouched",
	} {
		if got := r.Header.Get(key); got != want {
			t.Errorf("%s=%q, want %q", key, got, want)
		}
	}
}

func sendRetryPolicyRequest(t *testing.T, proxyURL string) (*http.Response, string) {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, proxyURL+"/v1/responses?trace=a%2Fb", strings.NewReader(retryPolicyRequestBody))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer test-secret")
	req.Header.Set("Idempotency-Key", "caller-owned-key")
	req.Header.Set("X-Custom", "untouched")
	resp, err := (&http.Client{Timeout: 3 * time.Second}).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, readErr := io.ReadAll(resp.Body)
	resp.Body.Close()
	if readErr != nil {
		t.Fatal(readErr)
	}
	return resp, string(body)
}

func TestRetryPolicyHTTPClassificationAndTransparency(t *testing.T) {
	tests := []struct {
		name   string
		status int
		error  string
		retry  bool
	}{
		{"bad request", 400, `{"error":{"type":"invalid_request_error","message":"invalid input"}}`, false},
		{"unauthorized", 401, `{"error":{"type":"authentication_error","message":"invalid key"}}`, false},
		{"not found", 404, `{"error":{"code":"model_not_found","message":"unknown model"}}`, false},
		{"request timeout", 408, `{"error":{"message":"timeout"}}`, true},
		{"too early", 425, `{"error":{"message":"too early"}}`, true},
		{"rate limited", 429, `{"error":{"code":"rate_limit_exceeded","message":"slow down"}}`, true},
		{"channel usage limit", 429, `{"error":{"type":"usage_limit_reached","message":"channel exhausted"}}`, true},
		{"insufficient quota", 429, `{"error":{"code":"insufficient_quota","message":"billing quota exhausted"}}`, false},
		{"internal error", 500, `{"error":{"type":"server_error","message":"internal error"}}`, true},
		{"bad gateway", 502, `{"error":{"message":"bad gateway"}}`, true},
		{"unavailable", 503, `{"error":{"code":"server_is_overloaded","message":"overloaded"}}`, true},
		{"gateway timeout", 504, `{"error":{"message":"gateway timeout"}}`, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var attempts atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				checkRetryPolicyRequest(t, r)
				attempt := attempts.Add(1)
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("X-Upstream-Attempt", fmt.Sprint(attempt))
				if attempt == 1 {
					w.WriteHeader(tt.status)
					_, _ = io.WriteString(w, tt.error)
					return
				}
				w.WriteHeader(http.StatusCreated)
				_, _ = io.WriteString(w, "{\n  \"result\": \"success\"\n}")
			}))
			defer upstream.Close()
			server := testProxy(t, upstream, 1)
			defer server.Close()
			resp, body := sendRetryPolicyRequest(t, server.URL)
			wantAttempts, wantStatus, wantBody := int32(1), tt.status, tt.error
			if tt.retry {
				wantAttempts, wantStatus, wantBody = 2, http.StatusCreated, "{\n  \"result\": \"success\"\n}"
			}
			if attempts.Load() != wantAttempts || resp.StatusCode != wantStatus || body != wantBody || resp.Header.Get("X-Upstream-Attempt") != fmt.Sprint(wantAttempts) {
				t.Fatalf("attempts=%d status=%d header=%q body=%q; want attempts=%d status=%d body=%q", attempts.Load(), resp.StatusCode, resp.Header.Get("X-Upstream-Attempt"), body, wantAttempts, wantStatus, wantBody)
			}
		})
	}
}

func TestRetryPolicySSEClassificationAndTransparency(t *testing.T) {
	tests := []struct {
		name  string
		error string
		retry bool
	}{
		{"capacity", `{"type":"service_unavailable_error","code":"server_is_overloaded","message":"overloaded"}`, true},
		{"usage limit", `{"type":"usage_limit_reached","message":"channel exhausted"}`, true},
		{"server error", `{"type":"server_error","message":"temporary failure"}`, true},
		{"unknown error", `{"type":"upstream_custom_failure","code":"unknown","message":"upstream failed"}`, true},
		{"empty error", `{}`, true},
		{"invalid input", `{"type":"invalid_request_error","message":"invalid input"}`, false},
		{"authentication", `{"type":"authentication_error","message":"invalid key"}`, false},
		{"permission", `{"type":"permission_error","message":"access denied"}`, false},
		{"context length", `{"code":"context_length_exceeded","message":"input is too long"}`, false},
		{"insufficient quota", `{"code":"insufficient_quota","message":"billing quota exhausted"}`, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var attempts atomic.Int32
			failed := "event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"error\":" + tt.error + "}}\n\n"
			success := "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\"}\n\n"
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				checkRetryPolicyRequest(t, r)
				attempt := attempts.Add(1)
				w.Header().Set("Content-Type", "text/event-stream")
				w.Header().Set("X-Upstream-Attempt", fmt.Sprint(attempt))
				if attempt == 1 {
					_, _ = io.WriteString(w, failed)
					return
				}
				_, _ = io.WriteString(w, success)
			}))
			defer upstream.Close()
			server := testProxy(t, upstream, 1)
			defer server.Close()
			resp, body := sendRetryPolicyRequest(t, server.URL)
			wantAttempts, wantBody := int32(1), failed
			if tt.retry {
				wantAttempts, wantBody = 2, success
			}
			if attempts.Load() != wantAttempts || resp.StatusCode != http.StatusOK || body != wantBody || resp.Header.Get("X-Upstream-Attempt") != fmt.Sprint(wantAttempts) || resp.Header.Get("Content-Type") != "text/event-stream" {
				t.Fatalf("attempts=%d status=%d headers=%v body=%q; want attempts=%d body=%q", attempts.Load(), resp.StatusCode, resp.Header, body, wantAttempts, wantBody)
			}
		})
	}
}

func TestRetryPolicySSECommentsDoNotCommit(t *testing.T) {
	for _, heartbeat := range []string{": ping\n\n", ": heartbeat\r\n\r\n", ":\n\n", "\n\n"} {
		t.Run(fmt.Sprintf("%q", heartbeat), func(t *testing.T) {
			var attempts atomic.Int32
			const success = "event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n"
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				checkRetryPolicyRequest(t, r)
				w.Header().Set("Content-Type", "text/event-stream")
				if attempts.Add(1) == 1 {
					_, _ = io.WriteString(w, heartbeat)
					w.(http.Flusher).Flush()
					_, _ = io.WriteString(w, "event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_is_overloaded\"}}}\n\n")
					return
				}
				_, _ = io.WriteString(w, success)
			}))
			defer upstream.Close()
			server := testProxy(t, upstream, 1)
			defer server.Close()
			resp, body := sendRetryPolicyRequest(t, server.URL)
			if attempts.Load() != 2 || resp.StatusCode != http.StatusOK || body != success {
				t.Fatalf("attempts=%d status=%d body=%q", attempts.Load(), resp.StatusCode, body)
			}
		})
	}
}

func TestRetryPolicySSEBeforeOutputEOFRetries(t *testing.T) {
	for _, prefix := range []string{"", "event: response.metadata\ndata: {\"type\":\"response.metadata\"}\n\n", ": ping\n\n"} {
		t.Run(fmt.Sprintf("%q", prefix), func(t *testing.T) {
			var attempts atomic.Int32
			const success = "event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n"
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				checkRetryPolicyRequest(t, r)
				w.Header().Set("Content-Type", "text/event-stream")
				if attempts.Add(1) == 1 {
					_, _ = io.WriteString(w, prefix)
					return
				}
				_, _ = io.WriteString(w, success)
			}))
			defer upstream.Close()
			server := testProxy(t, upstream, 1)
			defer server.Close()
			resp, body := sendRetryPolicyRequest(t, server.URL)
			if attempts.Load() != 2 || resp.StatusCode != http.StatusOK || body != success {
				t.Fatalf("attempts=%d status=%d body=%q", attempts.Load(), resp.StatusCode, body)
			}
		})
	}
}

func TestRetryPolicySSEExhaustedEOFReturnsBadGateway(t *testing.T) {
	var attempts atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		checkRetryPolicyRequest(t, r)
		attempts.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, "event: response.metadata\ndata: {\"type\":\"response.metadata\"}\n\n")
	}))
	defer upstream.Close()
	server := testProxy(t, upstream, 1)
	defer server.Close()
	resp, body := sendRetryPolicyRequest(t, server.URL)
	if attempts.Load() != 2 || resp.StatusCode != http.StatusBadGateway || strings.Contains(body, "response.metadata") {
		t.Fatalf("attempts=%d status=%d body=%q", attempts.Load(), resp.StatusCode, body)
	}
}

func TestRetryPolicySSECommittedOutputNeverRetries(t *testing.T) {
	var attempts atomic.Int32
	const exactBody = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"visible\"}\n\nevent: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_is_overloaded\"}}}\n\n"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		checkRetryPolicyRequest(t, r)
		attempts.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Upstream", "unchanged")
		_, _ = io.WriteString(w, exactBody)
	}))
	defer upstream.Close()
	server := testProxy(t, upstream, 3)
	defer server.Close()
	resp, body := sendRetryPolicyRequest(t, server.URL)
	if attempts.Load() != 1 || resp.StatusCode != http.StatusOK || body != exactBody || resp.Header.Get("X-Upstream") != "unchanged" {
		t.Fatalf("attempts=%d status=%d body=%q", attempts.Load(), resp.StatusCode, body)
	}
}

func TestRetryPolicyBufferedIncompleteBusinessResultDoesNotRetry(t *testing.T) {
	var attempts atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		checkRetryPolicyRequest(t, r)
		attempts.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n")
		_, _ = io.WriteString(w, "event: response.incomplete\ndata: {\"type\":\"response.incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}\n\n")
	}))
	defer upstream.Close()
	u, err := url.Parse(upstream.URL + "/v1")
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(&proxy{cfg: config{upstream: u, maxRetries: 2, backoff: 0, maxRetryWait: time.Second, bufferUntilSuccess: true}, client: upstream.Client()})
	defer server.Close()
	resp, body := sendRetryPolicyRequest(t, server.URL)
	if attempts.Load() != 1 || resp.StatusCode != http.StatusOK || !strings.Contains(body, "partial") || !strings.Contains(body, "response.incomplete") {
		t.Fatalf("attempts=%d status=%d body=%q", attempts.Load(), resp.StatusCode, body)
	}
}
