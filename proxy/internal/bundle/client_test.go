package bundle

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func bundleJSON(version int) string {
	return fmt.Sprintf(`{
		"schema_version": 1,
		"bundle_version": %d,
		"compiled_at": "2026-06-21T00:00:00Z",
		"org_settings": {"l7_enabled": false},
		"jwks": [],
		"apps": [
			{"id":"app-1","hostname":"wiki.internal","virtual_ip":"10.99.0.5",
			 "backend":"http://wiki:8080","tls_mode":"terminate",
			 "cert_source":"upload","cert_pem":"","l7_rules":[],
			 "allowed_group_ids":["g-1"],"inject_headers":[],"strip_headers":[]}
		],
		"groups": [{"id":"g-1","name":"devops","user_ids":["u-1"]}]
	}`, version)
}

func TestFetch_FirstCall_Stores200Body(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Accept") != "application/json" {
			t.Errorf("expected Accept: application/json, got %q", r.Header.Get("Accept"))
		}
		// First call should NOT have ?since (no prior bundle).
		if r.URL.RawQuery != "" {
			t.Errorf("expected empty query, got %q", r.URL.RawQuery)
		}
		w.Header().Set("ETag", `"v1"`)
		w.WriteHeader(200)
		fmt.Fprint(w, bundleJSON(1))
	}))
	defer srv.Close()

	c := New(srv.URL)
	v, changed, err := c.Fetch(context.Background())
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if v != 1 {
		t.Errorf("version: want 1, got %d", v)
	}
	if !changed {
		t.Error("expected changed=true on first fetch")
	}

	b := c.Current()
	if b == nil {
		t.Fatal("Current() returned nil after successful fetch")
	}
	if b.BundleVersion != 1 {
		t.Errorf("Current().BundleVersion: want 1, got %d", b.BundleVersion)
	}
	if app := b.FindAppByVIP("10.99.0.5"); app == nil || app.Hostname != "wiki.internal" {
		t.Errorf("FindAppByVIP failed; got %+v", app)
	}
}

func TestFetch_304_LeavesCachedBundle(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			w.Header().Set("ETag", `"v7"`)
			w.WriteHeader(200)
			fmt.Fprint(w, bundleJSON(7))
			return
		}
		// 2nd call: client should send If-None-Match: "v7" + ?since=7.
		if got := r.Header.Get("If-None-Match"); got != `"v7"` {
			t.Errorf("If-None-Match: want %q, got %q", `"v7"`, got)
		}
		if !strings.Contains(r.URL.RawQuery, "since=7") {
			t.Errorf("expected since=7 in query, got %q", r.URL.RawQuery)
		}
		w.WriteHeader(304)
	}))
	defer srv.Close()

	c := New(srv.URL)
	if _, changed, err := c.Fetch(context.Background()); err != nil || !changed {
		t.Fatalf("first fetch: changed=%v err=%v", changed, err)
	}
	v, changed, err := c.Fetch(context.Background())
	if err != nil {
		t.Fatalf("second fetch: %v", err)
	}
	if changed {
		t.Error("expected changed=false on 304")
	}
	if v != 7 {
		t.Errorf("version: want 7, got %d", v)
	}
}

func TestFetch_ErrorsOn304WithoutCachedBundle(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(304)
	}))
	defer srv.Close()

	c := New(srv.URL)
	if _, _, err := c.Fetch(context.Background()); err == nil {
		t.Fatal("expected error when server returns 304 with no cached bundle")
	}
}

func TestFetch_503BundleNotCompiled(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(503)
		fmt.Fprint(w, `{"error":"bundle_not_compiled"}`)
	}))
	defer srv.Close()

	c := New(srv.URL)
	_, _, err := c.Fetch(context.Background())
	if err == nil || !strings.Contains(err.Error(), "bundle_not_compiled") {
		t.Fatalf("want error mentioning bundle_not_compiled, got %v", err)
	}
}

func TestBundle_FindGroup(t *testing.T) {
	var b Bundle
	if err := json.Unmarshal([]byte(bundleJSON(1)), &b); err != nil {
		t.Fatal(err)
	}
	if g := b.FindGroup("g-1"); g == nil || g.Name != "devops" {
		t.Errorf("FindGroup(g-1): got %+v", g)
	}
	if g := b.FindGroup("missing"); g != nil {
		t.Errorf("FindGroup(missing): expected nil, got %+v", g)
	}
}
