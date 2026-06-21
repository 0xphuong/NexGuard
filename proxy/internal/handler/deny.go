package handler

import (
	"fmt"
	"html"
	"net/http"
)

// RenderDenyHTML writes a minimal, self-contained HTML deny page.
// `reason` is the machine code mirrored in the X-NexGuard-Reason
// header; `hostname` is the declared app the request targeted (may
// be empty when we don't even know which app — e.g. unknown VIP).
//
// Inline CSS so there's no second request to a stylesheet that
// might also fail. No JS. Reason is HTML-escaped — even though we
// only ever pass an enum value, defense in depth against future
// refactors that pass user input.
func RenderDenyHTML(w http.ResponseWriter, code int, reason, hostname string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(code)

	safeReason := html.EscapeString(reason)
	safeHost := html.EscapeString(hostname)
	title := titleFor(code)

	body := fmt.Sprintf(denyTemplate, code, title, code, title, safeHost, safeReason)
	_, _ = w.Write([]byte(body))
}

func titleFor(code int) string {
	switch code {
	case http.StatusUnauthorized:
		return "Authentication required"
	case http.StatusForbidden:
		return "Access denied"
	case http.StatusNotFound:
		return "Application not configured"
	case http.StatusBadGateway:
		return "Backend unavailable"
	case http.StatusServiceUnavailable:
		return "Gateway not ready"
	default:
		return http.StatusText(code)
	}
}

const denyTemplate = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>%d %s — NexGuard</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif;
         max-width: 560px; margin: 8vh auto; padding: 0 1.5rem;
         color: #1a1a1a; line-height: 1.5; }
  h1   { font-size: 1.5rem; margin-bottom: 0.5rem; }
  .code { color: #888; font-size: 0.9rem; letter-spacing: 0.1em;
          text-transform: uppercase; margin-bottom: 1.5rem; }
  .meta { background: #f4f4f4; padding: 0.75rem 1rem; border-radius: 6px;
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 0.85rem; color: #444; }
  .meta span { color: #888; }
  footer { margin-top: 2rem; font-size: 0.85rem; color: #888; }
</style>
</head>
<body>
  <div class="code">NexGuard · %d</div>
  <h1>%s</h1>
  <p>This connection was denied by your organization's access policy.
     Contact your administrator if you believe this is in error.</p>
  <div class="meta">
    <span>app:</span> %s<br>
    <span>reason:</span> %s
  </div>
  <footer>NexGuard L7 ZTNA · request not forwarded to backend.</footer>
</body>
</html>
`
