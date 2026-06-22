// Package policy is the L7 authorization decision point (ADR-008,
// ADR-014). Pure Go, no I/O — every input is in memory by the time
// the request handler calls Decide().
//
// Decision model:
//
//   1. Break-glass: if identity.access_scope == "all", bypass all
//      checks. The admin who flipped a user to :all accepts the
//      audit trail and the org-wide consequences (ADR-008).
//
//   2. Group gating (app-wide): if app.allowed_group_ids is
//      non-empty, the user must be a member of at least one of
//      those groups. Membership is resolved via the bundle's
//      groups[].user_ids list — no second round-trip to the server.
//
//   3. Rule eval: first-match wins. Each rule may pin a method, a
//      path prefix, additional required groups, and a max MFA age.
//      A rule with empty method[] matches every verb; empty
//      path_prefix matches every path. If a rule matches AND its
//      gates pass, return its action ("allow" or "deny").
//
//   4. Default deny: if no rule matches, deny. An app with no rules
//      and no allowed_group_ids gating is effectively closed —
//      admins must declare intent.
package policy

import (
	"net/http"
	"path"
	"strings"

	"github.com/0xphuong/NexGuard/proxy/internal/bundle"
	"github.com/0xphuong/NexGuard/proxy/internal/identity"
)

// Decision is the result of evaluating one (app, identity, request)
// triple against the bundle. Reason + MatchedRule are for logging;
// Allow drives the proxy's accept/deny path.
type Decision struct {
	Allow       bool
	Reason      string
	MatchedRule int // -1 if no rule matched / break-glass / group denial
}

const (
	reasonBreakGlass        = "break-glass: access_scope=all"
	reasonGroupGate         = "group gate: user not in any allowed group"
	reasonNoMatchDefaultDeny = "no rule matched; default deny"
	reasonRuleAllow         = "rule matched: allow"
	reasonRuleDeny          = "rule matched: deny"
)

// Decide runs the (app, identity, request) triple through the
// decision model documented above. Returns a Decision that the
// caller logs verbatim — never throws.
func Decide(b *bundle.Bundle, app *bundle.App, id *identity.Identity, req *http.Request) Decision {
	// 1. Break-glass.
	if id.AccessScope == "all" {
		return Decision{Allow: true, Reason: reasonBreakGlass, MatchedRule: -1}
	}

	// 2. App-wide group gate.
	if len(app.AllowedGroupIDs) > 0 && !userInAnyAllowedGroup(b, app, id.UserID) {
		return Decision{Allow: false, Reason: reasonGroupGate, MatchedRule: -1}
	}

	// 3. Rule eval — first match wins.
	for i, rule := range app.L7Rules {
		if !ruleMatches(rule, req) {
			continue
		}
		if !rulePostConditions(b, rule, id) {
			// Method/path matched but a require_groups or
			// require_mfa_age_seconds gate failed — continue scanning,
			// don't short-circuit to deny. A later rule may match.
			continue
		}

		switch rule.Action {
		case "allow":
			return Decision{Allow: true, Reason: reasonRuleAllow, MatchedRule: i}
		case "deny":
			return Decision{Allow: false, Reason: reasonRuleDeny, MatchedRule: i}
		default:
			// Unknown action — fail closed.
			return Decision{Allow: false, Reason: "rule matched: unknown action " + rule.Action, MatchedRule: i}
		}
	}

	// 4. No rule matched → default deny.
	return Decision{Allow: false, Reason: reasonNoMatchDefaultDeny, MatchedRule: -1}
}

// userInAnyAllowedGroup checks user_id membership against the bundle's
// per-group user_ids lists. Resolves the IDs via Bundle.FindGroup —
// O(apps_count × groups_count); fine for the few-hundred-group scale.
func userInAnyAllowedGroup(b *bundle.Bundle, app *bundle.App, userID string) bool {
	for _, gid := range app.AllowedGroupIDs {
		g := b.FindGroup(gid)
		if g == nil {
			// Stale bundle: app references a deleted group. Skip — the
			// next bundle compile should reconcile.
			continue
		}
		if g.IsMember(userID) {
			return true
		}
	}
	return false
}

// ruleMatches checks the request-shape side of the rule: method +
// path prefix. The identity-side gates (require_groups,
// require_mfa_age_seconds) are evaluated separately in
// rulePostConditions so a clear log message can distinguish "method
// didn't match" from "user lacks group".
func ruleMatches(r bundle.Rule, req *http.Request) bool {
	if len(r.Method) > 0 {
		if !contains(r.Method, req.Method) {
			return false
		}
	}
	if r.PathPrefix != "" {
		// Defense against path-traversal bypass: a request to
		// `/public/../admin/secret` would naively prefix-match
		// `/public/` BUT resolves to `/admin/secret` once the
		// backend cleans it. Reject any path that contains `..` so
		// it never matches a permissive rule — and compare against
		// the cleaned form so trailing-slash / "//" variants line up.
		if strings.Contains(req.URL.Path, "..") {
			return false
		}
		clean := path.Clean("/" + strings.TrimPrefix(req.URL.Path, "/"))
		if !strings.HasPrefix(clean, r.PathPrefix) {
			return false
		}
	}
	return true
}

// rulePostConditions evaluates the identity-side gates a rule attaches.
//
// require_groups: identity must be in at least one of the listed groups.
// require_mfa_age_seconds: identity.mfa_age_seconds MUST be non-nil
// AND less than or equal to the threshold. nil MFA fails-closed —
// per ADR-010 the proxy treats "no MFA configured" as not-fresh-enough.
func rulePostConditions(b *bundle.Bundle, r bundle.Rule, id *identity.Identity) bool {
	if len(r.RequireGroups) > 0 {
		// require_groups in the rule schema uses group names (per
		// ADR-008 example — "wiki-admins"). identity.groups is also
		// names, so this is a direct intersection.
		_ = b // bundle not needed for name-based check; reserved for future ID-based gating.
		if !id.HasAnyGroup(r.RequireGroups) {
			return false
		}
	}
	if r.RequireMFAAgeSeconds != nil {
		if id.MFAAgeSeconds == nil {
			return false
		}
		if *id.MFAAgeSeconds > *r.RequireMFAAgeSeconds {
			return false
		}
	}
	return true
}

func contains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}
