package handler

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRenderDenyHTML_Includes_Code_Title_Hostname_RequestID(t *testing.T) {
	rec := httptest.NewRecorder()
	RenderDenyHTML(rec, http.StatusForbidden, "denied", "wiki.internal", "abc123def456")

	if rec.Code != http.StatusForbidden {
		t.Errorf("code: want 403, got %d", rec.Code)
	}
	body := rec.Body.String()
	wants := []string{
		"403",                  // status code
		"Access not permitted", // friendly title
		"Policy denied",        // badge
		"denied",               // machine reason in details
		"wiki.internal",        // app hostname
		"abc123def456",         // request ID
		"NexGuard",             // brand
		"What to do next",      // action panel header
	}
	for _, want := range wants {
		if !strings.Contains(body, want) {
			t.Errorf("body missing %q", want)
		}
	}
	if got := rec.Header().Get("Content-Type"); !strings.HasPrefix(got, "text/html") {
		t.Errorf("Content-Type: want text/html, got %q", got)
	}
}

func TestRenderDenyHTML_EscapesUserInputDefensively(t *testing.T) {
	rec := httptest.NewRecorder()
	RenderDenyHTML(rec, 403, "<script>alert(1)</script>", "<b>host</b>", "id123")

	body := rec.Body.String()
	if strings.Contains(body, "<script>alert(1)</script>") {
		t.Errorf("raw <script> reflected into page — XSS risk")
	}
	if strings.Contains(body, "<b>host</b>") {
		t.Errorf("raw HTML in hostname not escaped")
	}
	// html/template auto-escapes to &lt;script&gt; etc. — sanity check.
	if !strings.Contains(body, "&lt;script&gt;") {
		t.Errorf("expected HTML-escaped reason in body; got %q", body)
	}
}

func TestRenderDenyHTML_Tone_PolicyVsInfra(t *testing.T) {
	// Policy statuses get the amber "policy" badge class.
	policyRec := httptest.NewRecorder()
	RenderDenyHTML(policyRec, http.StatusForbidden, "denied", "x", "id")
	if !strings.Contains(policyRec.Body.String(), `class="status-badge policy"`) {
		t.Errorf("403 should carry the .policy badge class")
	}

	// Infra statuses (502, 503) get the blue "infra" badge class.
	infraRec := httptest.NewRecorder()
	RenderDenyHTML(infraRec, http.StatusBadGateway, "backend-error", "x", "id")
	if !strings.Contains(infraRec.Body.String(), `class="status-badge infra"`) {
		t.Errorf("502 should carry the .infra badge class")
	}
}

func TestRenderDenyHTML_PerStatusMessaging(t *testing.T) {
	cases := []struct {
		code   int
		mustSee []string
	}{
		{http.StatusUnauthorized, []string{"Authentication required", "Unauthenticated", "Reconnect"}},
		{http.StatusForbidden, []string{"Access not permitted", "Policy denied", "administrator"}},
		{http.StatusNotFound, []string{"Application not found", "Not registered", "URL"}},
		{http.StatusBadGateway, []string{"Application unavailable", "Upstream error", "temporary"}},
		{http.StatusServiceUnavailable, []string{"Gateway not ready", "Gateway starting"}},
	}
	for _, c := range cases {
		rec := httptest.NewRecorder()
		RenderDenyHTML(rec, c.code, "test-reason", "x", "id")
		body := rec.Body.String()
		for _, w := range c.mustSee {
			if !strings.Contains(body, w) {
				t.Errorf("%d body missing %q", c.code, w)
			}
		}
	}
}

func TestRenderDenyHTML_OmitsHostnameRowWhenEmpty(t *testing.T) {
	// Unknown-VIP path has no hostname — the App row in technical
	// details should be skipped, not render an empty `App:` line.
	rec := httptest.NewRecorder()
	RenderDenyHTML(rec, http.StatusNotFound, "unknown-app", "", "id")
	body := rec.Body.String()
	if strings.Contains(body, `<span class="meta-key">App</span>`) {
		t.Errorf("hostname empty should hide the App row; body=%q", body)
	}
}
