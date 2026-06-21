package identity

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func okPayload(t *testing.T) string {
	t.Helper()
	return `{
		"user_id": "u-1",
		"email": "alice@example.com",
		"role": "unprivileged",
		"access_scope": "limited",
		"groups": ["devops", "oncall"],
		"device_id": "d-1",
		"mfa_age_seconds": 142,
		"signed_in_at": "2026-06-21T08:00:00Z"
	}`
}

func TestLookup_FirstCall_FetchesAndCaches(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		if r.URL.Path != "/internal/sessions/by_vpn_ip/100.64.0.5" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		w.Header().Set("ETag", `W/"abc123"`)
		w.WriteHeader(200)
		fmt.Fprint(w, okPayload(t))
	}))
	defer srv.Close()

	c := New(srv.URL)
	id, err := c.Lookup(context.Background(), "100.64.0.5")
	if err != nil {
		t.Fatalf("lookup: %v", err)
	}
	if id.UserID != "u-1" || id.Email != "alice@example.com" {
		t.Errorf("unexpected identity %+v", id)
	}

	// Second call within TTL should hit cache → server still at 1 call.
	if _, err := c.Lookup(context.Background(), "100.64.0.5"); err != nil {
		t.Fatalf("cache lookup: %v", err)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Errorf("server calls: want 1 (cache hit), got %d", got)
	}
}

func TestLookup_404_ReturnsErrUnknownVPNIP_AndClearsCache(t *testing.T) {
	state := "ok"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if state == "ok" {
			w.Header().Set("ETag", `W/"abc"`)
			w.WriteHeader(200)
			fmt.Fprint(w, okPayload(t))
			return
		}
		w.WriteHeader(404)
		fmt.Fprint(w, `{"error":"unknown_vpn_ip"}`)
	}))
	defer srv.Close()

	c := New(srv.URL)
	c.TTL = 1 * time.Millisecond
	if _, err := c.Lookup(context.Background(), "100.64.0.5"); err != nil {
		t.Fatalf("first lookup: %v", err)
	}

	// Expire TTL and have server start 404ing.
	time.Sleep(5 * time.Millisecond)
	state = "404"

	_, err := c.Lookup(context.Background(), "100.64.0.5")
	if !errors.Is(err, ErrUnknownVPNIP) {
		t.Fatalf("want ErrUnknownVPNIP, got %v", err)
	}

	// Cache entry must be dropped on 404 so we don't keep handing out a stale identity.
	c.mu.RLock()
	_, ok := c.cache["100.64.0.5"]
	c.mu.RUnlock()
	if ok {
		t.Error("expected cache entry to be invalidated on 404")
	}
}

func TestLookup_304_RefreshesTTL_NoDecode(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c := atomic.AddInt32(&calls, 1)
		if c == 1 {
			w.Header().Set("ETag", `W/"v1"`)
			w.WriteHeader(200)
			fmt.Fprint(w, okPayload(t))
			return
		}
		if got := r.Header.Get("If-None-Match"); got != `W/"v1"` {
			t.Errorf("If-None-Match: want %q, got %q", `W/"v1"`, got)
		}
		w.WriteHeader(304)
	}))
	defer srv.Close()

	c := New(srv.URL)
	c.TTL = 1 * time.Millisecond
	if _, err := c.Lookup(context.Background(), "ip"); err != nil {
		t.Fatal(err)
	}
	time.Sleep(5 * time.Millisecond)

	id, err := c.Lookup(context.Background(), "ip")
	if err != nil {
		t.Fatalf("304 path: %v", err)
	}
	if id.Email != "alice@example.com" {
		t.Errorf("304 should keep cached identity, got %+v", id)
	}
}

func TestInvalidate(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", `"x"`)
		w.WriteHeader(200)
		fmt.Fprint(w, okPayload(t))
	}))
	defer srv.Close()

	c := New(srv.URL)
	if _, err := c.Lookup(context.Background(), "ip"); err != nil {
		t.Fatal(err)
	}
	c.Invalidate("ip")

	c.mu.RLock()
	_, ok := c.cache["ip"]
	c.mu.RUnlock()
	if ok {
		t.Error("expected cache entry gone after Invalidate")
	}
}

func TestHasAnyGroup(t *testing.T) {
	id := &Identity{Groups: []string{"devops", "oncall"}}

	if !id.HasAnyGroup([]string{"oncall"}) {
		t.Error("expected match on oncall")
	}
	if !id.HasAnyGroup([]string{"missing", "devops"}) {
		t.Error("expected match on devops")
	}
	if id.HasAnyGroup([]string{"alpha", "beta"}) {
		t.Error("expected no match")
	}
	if id.HasAnyGroup(nil) {
		t.Error("nil group list should not match anything")
	}
}
