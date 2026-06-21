// Package identity wraps the NexGuard /internal/sessions/by_vpn_ip/:ip
// endpoint with a TTL cache + ETag-aware refresh.
package identity

import "time"

// Identity mirrors the JSON the server emits — see the server
// runbook docs/migrations/v2.3.0.md or NEXGUARD_LOGIC.md §17 for
// the canonical shape.
type Identity struct {
	UserID         string   `json:"user_id"`
	Email          string   `json:"email"`
	Role           string   `json:"role"`
	AccessScope    string   `json:"access_scope"`
	Groups         []string `json:"groups"`
	DeviceID       string   `json:"device_id"`
	MFAAgeSeconds  *int     `json:"mfa_age_seconds"`
	SignedInAt     string   `json:"signed_in_at"`
}

// HasGroup reports whether the identity is a member of any of the
// supplied group IDs. Used by the proxy's group-intersection check
// (ADR-014) — note this matches against group **names**, not IDs,
// because the identity payload carries names; the App's
// allowed_group_ids are translated via Bundle.FindGroup at the
// rule-eval layer.
func (i *Identity) HasAnyGroup(groupNames []string) bool {
	for _, g := range groupNames {
		for _, mine := range i.Groups {
			if mine == g {
				return true
			}
		}
	}
	return false
}

// entry is the internal cache record.
type entry struct {
	identity  *Identity
	etag      string
	expiresAt time.Time
}
