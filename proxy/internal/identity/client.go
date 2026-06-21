package identity

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

// ErrUnknownVPNIP signals the server returned 404 — the VPN IP does
// not match any active device or the owning user is disabled. Per
// ADR-010 the proxy treats this as "deny + force re-auth".
var ErrUnknownVPNIP = errors.New("identity: unknown_vpn_ip")

// TTL the proxy keeps an identity cached for. Matches the server's
// Cache-Control: private, max-age=30 header — kept in code rather
// than parsed from the header to keep behavior explicit and easy
// to test.
const DefaultTTL = 30 * time.Second

// Client is a thread-safe identity resolver with a per-VPN-IP cache.
//
// Concurrency: cache reads/writes go through a sync.RWMutex. A burst
// of concurrent requests for the same fresh IP will all return the
// same cached entry without re-fetching.
type Client struct {
	BaseURL    string
	HTTPClient *http.Client
	TTL        time.Duration

	mu    sync.RWMutex
	cache map[string]entry
	now   func() time.Time
}

func New(baseURL string) *Client {
	return &Client{
		BaseURL: baseURL,
		HTTPClient: &http.Client{
			Timeout: 5 * time.Second,
		},
		TTL:   DefaultTTL,
		cache: make(map[string]entry),
		now:   time.Now,
	}
}

// Lookup returns the identity for a given VPN IP, hitting the cache
// when the entry is fresh. On cache miss or expired entry, issues a
// conditional GET (If-None-Match) and refreshes the TTL.
//
// Returns ErrUnknownVPNIP when the server 404s.
func (c *Client) Lookup(ctx context.Context, vpnIP string) (*Identity, error) {
	if id, ok := c.lookupCache(vpnIP); ok {
		return id, nil
	}
	return c.fetch(ctx, vpnIP)
}

// Invalidate drops the cached entry for an IP, forcing the next
// Lookup to hit the server. The proxy calls this from the
// :identity_updated event handler.
func (c *Client) Invalidate(vpnIP string) {
	c.mu.Lock()
	delete(c.cache, vpnIP)
	c.mu.Unlock()
}

// InvalidateAll drops the whole cache. Used on bundle pivot or on
// a reconnect after a long PubSub channel outage.
func (c *Client) InvalidateAll() {
	c.mu.Lock()
	c.cache = make(map[string]entry)
	c.mu.Unlock()
}

func (c *Client) lookupCache(vpnIP string) (*Identity, bool) {
	c.mu.RLock()
	e, ok := c.cache[vpnIP]
	c.mu.RUnlock()
	if !ok {
		return nil, false
	}
	if c.now().After(e.expiresAt) {
		return nil, false
	}
	return e.identity, true
}

func (c *Client) fetch(ctx context.Context, vpnIP string) (*Identity, error) {
	url := fmt.Sprintf("%s/internal/sessions/by_vpn_ip/%s", c.BaseURL, vpnIP)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")

	c.mu.RLock()
	if e, ok := c.cache[vpnIP]; ok && e.etag != "" {
		req.Header.Set("If-None-Match", e.etag)
	}
	c.mu.RUnlock()

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("identity fetch: %w", err)
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusNotFound:
		// Drop any stale entry — server says this IP is no longer valid.
		c.Invalidate(vpnIP)
		return nil, ErrUnknownVPNIP

	case http.StatusNotModified:
		c.mu.Lock()
		e, ok := c.cache[vpnIP]
		if ok {
			e.expiresAt = c.now().Add(c.TTL)
			c.cache[vpnIP] = e
		}
		c.mu.Unlock()
		if !ok {
			return nil, errors.New("identity: 304 with no cached entry")
		}
		return e.identity, nil

	case http.StatusOK:
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, fmt.Errorf("identity read body: %w", err)
		}
		var id Identity
		if err := json.Unmarshal(body, &id); err != nil {
			return nil, fmt.Errorf("identity decode: %w", err)
		}
		etag := resp.Header.Get("ETag")

		c.mu.Lock()
		c.cache[vpnIP] = entry{
			identity:  &id,
			etag:      etag,
			expiresAt: c.now().Add(c.TTL),
		}
		c.mu.Unlock()
		return &id, nil

	default:
		return nil, fmt.Errorf("identity: unexpected HTTP %d", resp.StatusCode)
	}
}
