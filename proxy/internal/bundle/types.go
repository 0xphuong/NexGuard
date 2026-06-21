// Package bundle holds the wire-level shape of the policy bundle the
// NexGuard server compiles at /internal/bundle.json (ADR-010, ADR-013).
//
// The schema is mirrored from FzHttp.L7.BundleBuilder; keep changes
// here in sync with apps/fz_http/lib/fz_http/l7/bundle_builder.ex on
// the server side.
package bundle

// Bundle is the full policy snapshot the proxy reads on startup and
// re-reads on every {:bundle_updated, version} broadcast.
type Bundle struct {
	SchemaVersion int         `json:"schema_version"`
	BundleVersion int         `json:"bundle_version"`
	CompiledAt    string      `json:"compiled_at"`
	OrgSettings   OrgSettings `json:"org_settings"`
	JWKS          []JWK       `json:"jwks"`
	// SigningKey is the active key's PRIVATE half — the proxy uses it
	// to sign X-NexGuard-Identity-Jwt on every request. Treat the
	// whole Bundle as a secret-bearing artifact.
	SigningKey SigningKey `json:"signing_key"`
	Apps       []App      `json:"apps"`
	Groups     []Group    `json:"groups"`
}

// SigningKey carries the proxy's RS256 signing material.
type SigningKey struct {
	Kid        string `json:"kid"`
	Algorithm  string `json:"algorithm"`
	PrivatePEM string `json:"private_pem"`
}

type OrgSettings struct {
	L7Enabled bool `json:"l7_enabled"`
}

// JWK is the RFC 7517 public-key projection. The "kid" header in any
// JWT received from NexGuard maps to one of these.
type JWK struct {
	Kid string `json:"kid"`
	Kty string `json:"kty"`
	Alg string `json:"alg"`
	Use string `json:"use"`
	N   string `json:"n"`
	E   string `json:"e"`
}

// App is one declared L7 application.
type App struct {
	ID              string   `json:"id"`
	Hostname        string   `json:"hostname"`
	VirtualIP       string   `json:"virtual_ip"`
	Backend         string   `json:"backend"`
	TLSMode         string   `json:"tls_mode"`
	CertSource      string   `json:"cert_source"`
	CertPEM         string   `json:"cert_pem"`
	KeyPEM          string   `json:"key_pem"`
	L7Rules         []Rule   `json:"l7_rules"`
	AllowedGroupIDs []string `json:"allowed_group_ids"`
	InjectHeaders   []Header `json:"inject_headers"`
	StripHeaders    []string `json:"strip_headers"`
}

// Rule is one entry in an App's l7_rules array. Schema per ADR-008.
// `Method` is an array — admins commonly grant multiple verbs at
// once. An empty array means the rule matches every method.
type Rule struct {
	Action               string   `json:"action"`
	Method               []string `json:"method,omitempty"`
	PathPrefix           string   `json:"path_prefix,omitempty"`
	RequireGroups        []string `json:"require_groups,omitempty"`
	RequireMFAAgeSeconds *int     `json:"require_mfa_age_seconds,omitempty"`
}

type Header struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type Group struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	UserIDs []string `json:"user_ids"`
}

// IsMember reports whether userID is part of this group.
func (g *Group) IsMember(userID string) bool {
	for _, u := range g.UserIDs {
		if u == userID {
			return true
		}
	}
	return false
}

// FindAppByVIP returns the app declared at the given virtual IP, or
// nil if no app matches.
func (b *Bundle) FindAppByVIP(vip string) *App {
	for i := range b.Apps {
		if b.Apps[i].VirtualIP == vip {
			return &b.Apps[i]
		}
	}
	return nil
}

// FindGroup returns the group declared with the given ID, or nil.
func (b *Bundle) FindGroup(id string) *Group {
	for i := range b.Groups {
		if b.Groups[i].ID == id {
			return &b.Groups[i]
		}
	}
	return nil
}
