package observability

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthz_AlwaysOK(t *testing.T) {
	h := NewHealth()
	rec := httptest.NewRecorder()
	h.Healthz(rec, httptest.NewRequest("GET", "/healthz", nil))

	if rec.Code != 200 {
		t.Errorf("healthz: want 200, got %d", rec.Code)
	}
	if got := rec.Body.String(); got != "ok\n" {
		t.Errorf("body: got %q", got)
	}
}

func TestReadyz_503BeforeSetReady(t *testing.T) {
	h := NewHealth()
	rec := httptest.NewRecorder()
	h.Readyz(rec, httptest.NewRequest("GET", "/readyz", nil))

	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("readyz before SetReady: want 503, got %d", rec.Code)
	}
}

func TestReadyz_200AfterSetReady(t *testing.T) {
	h := NewHealth()
	h.SetReady(true)

	rec := httptest.NewRecorder()
	h.Readyz(rec, httptest.NewRequest("GET", "/readyz", nil))

	if rec.Code != 200 {
		t.Errorf("readyz after SetReady: want 200, got %d", rec.Code)
	}
}

func TestReadyz_TogglesBack(t *testing.T) {
	h := NewHealth()
	h.SetReady(true)
	h.SetReady(false)

	rec := httptest.NewRecorder()
	h.Readyz(rec, httptest.NewRequest("GET", "/readyz", nil))

	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("readyz after SetReady(false): want 503, got %d", rec.Code)
	}
}
