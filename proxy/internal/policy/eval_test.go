package policy

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/0xphuong/NexGuard/proxy/internal/bundle"
	"github.com/0xphuong/NexGuard/proxy/internal/identity"
)

func intp(n int) *int { return &n }

// helper to assemble a bundle with the group/app pair under test.
func newBundleFixture(app bundle.App, groups []bundle.Group) *bundle.Bundle {
	return &bundle.Bundle{
		SchemaVersion: 1,
		BundleVersion: 1,
		Apps:          []bundle.App{app},
		Groups:        groups,
	}
}

func req(t *testing.T, method, target string) *http.Request {
	t.Helper()
	return httptest.NewRequest(method, target, nil)
}

func TestDecide_BreakGlass_BypassesEverything(t *testing.T) {
	b := newBundleFixture(bundle.App{
		ID:              "app-1",
		AllowedGroupIDs: []string{"g-locked"},
		L7Rules:         []bundle.Rule{{Action: "deny"}}, // explicit deny-all
	}, []bundle.Group{
		{ID: "g-locked", Name: "locked", UserIDs: []string{}},
	})

	id := &identity.Identity{
		UserID:      "u-1",
		AccessScope: "all", // break-glass
	}

	d := Decide(b, &b.Apps[0], id, req(t, "GET", "/anything"))
	if !d.Allow {
		t.Fatalf("expected allow, got %+v", d)
	}
	if d.Reason != reasonBreakGlass {
		t.Errorf("reason: want %q, got %q", reasonBreakGlass, d.Reason)
	}
}

func TestDecide_GroupGate_DeniesNonMember(t *testing.T) {
	b := newBundleFixture(bundle.App{
		ID:              "app-1",
		AllowedGroupIDs: []string{"g-1"},
		L7Rules: []bundle.Rule{
			{Action: "allow"}, // would otherwise match
		},
	}, []bundle.Group{
		{ID: "g-1", Name: "devops", UserIDs: []string{"u-other"}},
	})

	id := &identity.Identity{
		UserID:      "u-1",
		AccessScope: "limited",
		Groups:      []string{"devops"}, // name match but user_id not in group
	}

	d := Decide(b, &b.Apps[0], id, req(t, "GET", "/"))
	if d.Allow {
		t.Fatalf("expected deny, got %+v", d)
	}
	if d.Reason != reasonGroupGate {
		t.Errorf("reason: want %q, got %q", reasonGroupGate, d.Reason)
	}
}

func TestDecide_GroupGate_AllowsMember(t *testing.T) {
	b := newBundleFixture(bundle.App{
		ID:              "app-1",
		AllowedGroupIDs: []string{"g-1"},
		L7Rules: []bundle.Rule{
			{Action: "allow", PathPrefix: "/"},
		},
	}, []bundle.Group{
		{ID: "g-1", UserIDs: []string{"u-1"}},
	})

	id := &identity.Identity{UserID: "u-1", AccessScope: "limited"}

	d := Decide(b, &b.Apps[0], id, req(t, "GET", "/"))
	if !d.Allow {
		t.Fatalf("expected allow, got %+v", d)
	}
}

func TestDecide_NoRules_DefaultDeny(t *testing.T) {
	b := newBundleFixture(bundle.App{
		ID:      "app-1",
		L7Rules: []bundle.Rule{}, // empty
	}, nil)

	id := &identity.Identity{UserID: "u-1", AccessScope: "limited"}

	d := Decide(b, &b.Apps[0], id, req(t, "GET", "/"))
	if d.Allow {
		t.Fatalf("expected deny with empty rule list, got %+v", d)
	}
	if d.Reason != reasonNoMatchDefaultDeny {
		t.Errorf("reason: %q", d.Reason)
	}
}

func TestDecide_MethodMatching(t *testing.T) {
	b := newBundleFixture(bundle.App{
		ID: "app-1",
		L7Rules: []bundle.Rule{
			{Action: "allow", Method: []string{"GET", "POST"}},
		},
	}, nil)
	id := &identity.Identity{UserID: "u-1", AccessScope: "limited"}

	if d := Decide(b, &b.Apps[0], id, req(t, "POST", "/")); !d.Allow {
		t.Errorf("POST should be allowed: %+v", d)
	}
	if d := Decide(b, &b.Apps[0], id, req(t, "DELETE", "/")); d.Allow {
		t.Errorf("DELETE should be denied (no rule covers it): %+v", d)
	}
}

func TestDecide_PathPrefix(t *testing.T) {
	b := newBundleFixture(bundle.App{
		ID: "app-1",
		L7Rules: []bundle.Rule{
			{Action: "allow", PathPrefix: "/api/"},
		},
	}, nil)
	id := &identity.Identity{UserID: "u-1", AccessScope: "limited"}

	if d := Decide(b, &b.Apps[0], id, req(t, "GET", "/api/widgets")); !d.Allow {
		t.Errorf("/api/widgets should match /api/ prefix: %+v", d)
	}
	if d := Decide(b, &b.Apps[0], id, req(t, "GET", "/dashboard")); d.Allow {
		t.Errorf("/dashboard should not match: %+v", d)
	}
}

func TestDecide_PathTraversalRejected(t *testing.T) {
	// Defense vs the classic bypass: an attacker tries
	// `/public/../admin/delete` hoping the prefix-only check
	// matches `/public/`. The path-normalisation guard in
	// ruleMatches rejects any URL containing `..` outright so the
	// rule falls through to default-deny.
	b := newBundleFixture(bundle.App{
		ID: "app-1",
		L7Rules: []bundle.Rule{
			{Action: "allow", PathPrefix: "/public/"},
			// no explicit catch-all — relying on default deny
		},
	}, nil)
	id := &identity.Identity{UserID: "u-1", AccessScope: "limited"}

	// Legit /public/* paths still allowed.
	if d := Decide(b, &b.Apps[0], id, req(t, "GET", "/public/index.html")); !d.Allow {
		t.Errorf("/public/index.html should pass: %+v", d)
	}

	// Traversal attempts MUST NOT match the /public/ rule.
	hostile := []string{
		"/public/../admin",
		"/public/../../etc/passwd",
		"/public/..%2fadmin", // raw URL-encoded dot-slash, not Clean'able but contains ".."
	}
	for _, p := range hostile {
		if d := Decide(b, &b.Apps[0], id, req(t, "GET", p)); d.Allow {
			t.Errorf("traversal %q should NOT match permissive rule, got %+v", p, d)
		}
	}
}

func TestDecide_FirstMatchWins(t *testing.T) {
	b := newBundleFixture(bundle.App{
		ID: "app-1",
		L7Rules: []bundle.Rule{
			{Action: "deny", PathPrefix: "/admin/"},
			{Action: "allow", PathPrefix: "/"},
		},
	}, nil)
	id := &identity.Identity{UserID: "u-1", AccessScope: "limited"}

	// /admin/foo matches the first rule (deny). The /-prefix rule
	// would also match but loses to first-match-wins.
	d := Decide(b, &b.Apps[0], id, req(t, "GET", "/admin/dashboard"))
	if d.Allow {
		t.Fatalf("expected deny from first matching rule, got %+v", d)
	}
	if d.MatchedRule != 0 {
		t.Errorf("MatchedRule: want 0, got %d", d.MatchedRule)
	}

	// /docs only matches the second rule.
	d = Decide(b, &b.Apps[0], id, req(t, "GET", "/docs"))
	if !d.Allow {
		t.Errorf("expected allow from second rule, got %+v", d)
	}
	if d.MatchedRule != 1 {
		t.Errorf("MatchedRule: want 1, got %d", d.MatchedRule)
	}
}

func TestDecide_RequireGroupsOnRule(t *testing.T) {
	b := newBundleFixture(bundle.App{
		ID: "app-1",
		L7Rules: []bundle.Rule{
			{Action: "allow", Method: []string{"DELETE"}, RequireGroups: []string{"admins"}},
			{Action: "allow", Method: []string{"GET"}},
		},
	}, nil)

	gotAdmin := &identity.Identity{UserID: "u-1", AccessScope: "limited", Groups: []string{"admins"}}
	notAdmin := &identity.Identity{UserID: "u-2", AccessScope: "limited", Groups: []string{"users"}}

	if d := Decide(b, &b.Apps[0], gotAdmin, req(t, "DELETE", "/x")); !d.Allow {
		t.Errorf("admin DELETE: want allow, got %+v", d)
	}
	if d := Decide(b, &b.Apps[0], notAdmin, req(t, "DELETE", "/x")); d.Allow {
		// DELETE matched rule 0 but require_groups failed → fall through;
		// rule 1 is GET-only → no match → default deny.
		t.Errorf("non-admin DELETE: want deny, got %+v", d)
	}
	if d := Decide(b, &b.Apps[0], notAdmin, req(t, "GET", "/x")); !d.Allow {
		t.Errorf("non-admin GET: want allow (rule 1), got %+v", d)
	}
}

func TestDecide_RequireMFAAge(t *testing.T) {
	b := newBundleFixture(bundle.App{
		ID: "app-1",
		L7Rules: []bundle.Rule{
			{Action: "allow", PathPrefix: "/", RequireMFAAgeSeconds: intp(300)},
		},
	}, nil)

	noMFA := &identity.Identity{UserID: "u-1", AccessScope: "limited", MFAAgeSeconds: nil}
	freshMFA := &identity.Identity{UserID: "u-1", AccessScope: "limited", MFAAgeSeconds: intp(100)}
	staleMFA := &identity.Identity{UserID: "u-1", AccessScope: "limited", MFAAgeSeconds: intp(900)}

	if d := Decide(b, &b.Apps[0], noMFA, req(t, "GET", "/")); d.Allow {
		t.Errorf("no-MFA: want deny, got %+v", d)
	}
	if d := Decide(b, &b.Apps[0], freshMFA, req(t, "GET", "/")); !d.Allow {
		t.Errorf("fresh MFA: want allow, got %+v", d)
	}
	if d := Decide(b, &b.Apps[0], staleMFA, req(t, "GET", "/")); d.Allow {
		t.Errorf("stale MFA: want deny, got %+v", d)
	}
}

func TestDecide_UnknownActionFailsClosed(t *testing.T) {
	b := newBundleFixture(bundle.App{
		ID: "app-1",
		L7Rules: []bundle.Rule{
			{Action: "audit", PathPrefix: "/"}, // not allow/deny
		},
	}, nil)
	id := &identity.Identity{UserID: "u-1", AccessScope: "limited"}

	d := Decide(b, &b.Apps[0], id, req(t, "GET", "/"))
	if d.Allow {
		t.Fatalf("unknown action must fail closed, got %+v", d)
	}
}

func TestDecide_GroupGateSkipsDeletedGroup(t *testing.T) {
	// A stale bundle references a now-deleted group; the proxy must
	// not crash — just skip the missing reference. If the user has no
	// membership in any remaining valid group, deny.
	b := newBundleFixture(bundle.App{
		ID:              "app-1",
		AllowedGroupIDs: []string{"g-deleted", "g-still-here"},
		L7Rules:         []bundle.Rule{{Action: "allow", PathPrefix: "/"}},
	}, []bundle.Group{
		// g-deleted is NOT in this slice (server has reconciled it
		// from the application_allowed_groups join but the bundle
		// snapshot is one tick stale).
		{ID: "g-still-here", UserIDs: []string{"u-1"}},
	})

	id := &identity.Identity{UserID: "u-1", AccessScope: "limited"}

	if d := Decide(b, &b.Apps[0], id, req(t, "GET", "/")); !d.Allow {
		t.Errorf("u-1 is in g-still-here; should allow, got %+v", d)
	}
}
