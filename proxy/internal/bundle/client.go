package bundle

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync/atomic"
	"time"
)

// Client fetches the policy bundle from NexGuard and serves the
// latest version atomically to the rest of the proxy.
//
// Concurrency model: Set/Current/swap go through an atomic.Pointer
// so request handlers reading the current bundle never block on a
// re-fetch in progress.
type Client struct {
	BaseURL    string
	HTTPClient *http.Client

	current atomic.Pointer[Bundle]
	etag    atomic.Pointer[string]
}

// New creates a Client with sane defaults. baseURL should point at
// the NexGuard portal (e.g. "https://nexguard.binhphuong.io.vn") —
// no trailing slash.
func New(baseURL string) *Client {
	return &Client{
		BaseURL: baseURL,
		HTTPClient: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

// Current returns the most-recently-fetched bundle, or nil if no
// successful fetch has happened yet.
func (c *Client) Current() *Bundle {
	return c.current.Load()
}

// Fetch issues a conditional GET. If the server returns 304 (etag
// matched or ?since=N satisfied), the current bundle is left in
// place. On 200, the new bundle replaces the old atomically.
//
// Returns the version of the bundle in use after the call (current
// or newly-fetched). The boolean is true if the call resulted in a
// version change.
func (c *Client) Fetch(ctx context.Context) (version int, changed bool, err error) {
	cur := c.Current()
	q := ""
	if cur != nil {
		q = fmt.Sprintf("?since=%d", cur.BundleVersion)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.BaseURL+"/internal/bundle.json"+q, nil)
	if err != nil {
		return 0, false, err
	}

	if e := c.etag.Load(); e != nil && *e != "" {
		req.Header.Set("If-None-Match", *e)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return 0, false, fmt.Errorf("bundle fetch: %w", err)
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusNotModified:
		if cur == nil {
			return 0, false, errors.New("bundle: server returned 304 but proxy has no cached bundle")
		}
		return cur.BundleVersion, false, nil

	case http.StatusOK:
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return 0, false, fmt.Errorf("bundle read body: %w", err)
		}

		var b Bundle
		if err := json.Unmarshal(body, &b); err != nil {
			return 0, false, fmt.Errorf("bundle decode: %w", err)
		}

		c.current.Store(&b)
		if et := resp.Header.Get("ETag"); et != "" {
			c.etag.Store(&et)
		}
		return b.BundleVersion, true, nil

	case http.StatusServiceUnavailable:
		return 0, false, errors.New("bundle: server reports bundle_not_compiled (503)")

	default:
		return 0, false, fmt.Errorf("bundle: unexpected HTTP %d", resp.StatusCode)
	}
}
