package handler

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRenderDenyHTML_Includes_Code_Reason_Hostname(t *testing.T) {
	rec := httptest.NewRecorder()
	RenderDenyHTML(rec, http.StatusForbidden, "denied", "wiki.internal")

	if rec.Code != http.StatusForbidden {
		t.Errorf("code: want 403, got %d", rec.Code)
	}
	body := rec.Body.String()
	for _, want := range []string{"403", "Access denied", "denied", "wiki.internal"} {
		if !strings.Contains(body, want) {
			t.Errorf("body missing %q; body=%q", want, body)
		}
	}
	if got := rec.Header().Get("Content-Type"); !strings.HasPrefix(got, "text/html") {
		t.Errorf("Content-Type: want text/html, got %q", got)
	}
}

func TestRenderDenyHTML_EscapesUserInputDefensively(t *testing.T) {
	rec := httptest.NewRecorder()
	RenderDenyHTML(rec, 403, "<script>alert(1)</script>", "<b>host</b>")

	body := rec.Body.String()
	if strings.Contains(body, "<script>") {
		t.Errorf("raw script tag found in deny page: %q", body)
	}
	if strings.Contains(body, "<b>host</b>") {
		t.Errorf("raw HTML in hostname not escaped: %q", body)
	}
}
