package handler

import (
	"html/template"
	"net/http"
	"time"
)

// RenderDenyHTML emits a self-contained HTML deny page styled like
// the enterprise access-gateway pages users already trust (Cloudflare
// Access, Google IAP, Okta) — calm, professional, with one piece of
// information the operator can act on: a short request ID the user
// can hand to support so admins can pivot directly into the proxy
// access log.
//
// Constraints baked into the design:
//   - No JS, no external assets, no external fonts (CSP-tight).
//   - Inline CSS only — single round-trip render, works under a
//     proxy refusing all sub-requests.
//   - Auto-adapts to prefers-color-scheme.
//   - html/template auto-escapes — defense in depth even though all
//     callers today pass enum values.
//
// Note: every interpolated value goes through html/template's
// context-aware escaping, so the explicit `html.EscapeString` calls
// from the previous version are no longer needed.
func RenderDenyHTML(w http.ResponseWriter, code int, reason, hostname, requestID string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(code)

	_ = denyTmpl.Execute(w, denyData{
		StatusCode: code,
		Badge:      badgeFor(code),
		Title:      titleFor(code),
		Lede:       ledeFor(code),
		NextSteps:  nextStepsFor(code),
		Hostname:   hostname,
		Reason:     reason,
		Time:       time.Now().UTC().Format("2006-01-02 15:04:05 UTC"),
		RequestID:  requestID,
		Tone:       toneFor(code),
	})
}

type denyData struct {
	StatusCode int
	Badge      string
	Title      string
	Lede       string
	NextSteps  string
	Hostname   string
	Reason     string
	Time       string
	RequestID  string
	Tone       string // "policy" (401/403/404) or "infra" (502/503)
}

func titleFor(code int) string {
	switch code {
	case http.StatusUnauthorized:
		return "Authentication required"
	case http.StatusForbidden:
		return "Access not permitted"
	case http.StatusNotFound:
		return "Application not found"
	case http.StatusBadGateway:
		return "Application unavailable"
	case http.StatusServiceUnavailable:
		return "Gateway not ready"
	default:
		return http.StatusText(code)
	}
}

func badgeFor(code int) string {
	switch code {
	case http.StatusUnauthorized:
		return "Unauthenticated"
	case http.StatusForbidden:
		return "Policy denied"
	case http.StatusNotFound:
		return "Not registered"
	case http.StatusBadGateway:
		return "Upstream error"
	case http.StatusServiceUnavailable:
		return "Gateway starting"
	default:
		return http.StatusText(code)
	}
}

func ledeFor(code int) string {
	switch code {
	case http.StatusUnauthorized:
		return "We don't recognize your session for this application. Your VPN connection may have dropped or your access was revoked."
	case http.StatusForbidden:
		return "Your current access policy doesn't include this application. The connection was filtered at the gateway and never reached the application."
	case http.StatusNotFound:
		return "There's no application configured at this address. The URL may be a typo, or this app was removed."
	case http.StatusBadGateway:
		return "We reached the policy gate, but the application itself didn't respond. This is almost always temporary."
	case http.StatusServiceUnavailable:
		return "NexGuard is still loading its access policy. This usually takes a few seconds after startup."
	default:
		return "The request was rejected by the gateway."
	}
}

func nextStepsFor(code int) string {
	switch code {
	case http.StatusUnauthorized:
		return "Reconnect to NexGuard VPN and try again. If you remain blocked, share the request ID below with your administrator."
	case http.StatusForbidden:
		return "If you believe you should have access, send the request ID below to your administrator — they can look it up in the audit log."
	case http.StatusNotFound:
		return "Double-check the URL. If it's correct, ask your administrator to register this application in NexGuard."
	case http.StatusBadGateway:
		return "Wait a few seconds and refresh. If the issue persists, share the request ID with your administrator."
	case http.StatusServiceUnavailable:
		return "Wait a few seconds and try again. If it still fails after a minute, the gateway may need attention."
	default:
		return "Refresh and try again. Share the request ID with your administrator if the issue persists."
	}
}

// toneFor splits statuses into "policy" (user-blocked) vs "infra"
// (temporary infrastructure issue) so the badge can pick a colour
// that matches the user's mental model — orange-amber means "you
// need to do something", indigo means "the system needs a moment".
func toneFor(code int) string {
	switch code {
	case http.StatusBadGateway, http.StatusServiceUnavailable:
		return "infra"
	default:
		return "policy"
	}
}

// denyTmpl is parsed once at package init. Subsequent calls reuse
// the compiled template, so the hot path is just .Execute.
var denyTmpl = template.Must(template.New("deny").Parse(denyTemplateSrc))

const denyTemplateSrc = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{.StatusCode}} {{.Title}} · NexGuard</title>
<style>
  *, *::before, *::after { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; }

  :root {
    color-scheme: light dark;
    --bg:           #fafafa;
    --bg-card:      #ffffff;
    --bg-soft:      #f4f4f5;
    --fg:           #18181b;
    --fg-muted:     #52525b;
    --fg-subtle:    #a1a1aa;
    --border:       #e4e4e7;
    --accent:       #4f46e5;
    --policy-bg:    #fef3c7;
    --policy-fg:    #92400e;
    --infra-bg:     #dbeafe;
    --infra-fg:     #1e3a8a;
    --shadow:       0 1px 2px rgba(15, 15, 18, 0.04),
                    0 12px 32px rgba(15, 15, 18, 0.06);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg:         #09090b;
      --bg-card:    #18181b;
      --bg-soft:    #27272a;
      --fg:         #fafafa;
      --fg-muted:   #a1a1aa;
      --fg-subtle:  #71717a;
      --border:     #27272a;
      --accent:     #818cf8;
      --policy-bg:  #422006;
      --policy-fg:  #fbbf24;
      --infra-bg:   #1e3a8a;
      --infra-fg:   #93c5fd;
      --shadow:     0 1px 2px rgba(0, 0, 0, 0.4),
                    0 12px 32px rgba(0, 0, 0, 0.5);
    }
  }

  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
                 Oxygen-Sans, Ubuntu, Cantarell, "Helvetica Neue", sans-serif;
    background: var(--bg);
    color: var(--fg);
    line-height: 1.55;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2rem 1.25rem;
    -webkit-font-smoothing: antialiased;
    -moz-osx-font-smoothing: grayscale;
  }

  main {
    max-width: 480px;
    width: 100%;
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: 14px;
    padding: 2rem;
    box-shadow: var(--shadow);
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    color: var(--fg-muted);
    font-size: 0.72rem;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    font-weight: 600;
    margin-bottom: 2rem;
  }
  .brand-mark {
    width: 18px;
    height: 18px;
    border-radius: 5px;
    background: var(--accent);
    display: grid;
    place-items: center;
    color: white;
    font-size: 11px;
    font-weight: 700;
    line-height: 1;
  }

  .status-row {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    margin-bottom: 0.5rem;
  }
  .status-code {
    font-size: 2.75rem;
    font-weight: 700;
    letter-spacing: -0.025em;
    color: var(--fg);
    font-variant-numeric: tabular-nums;
    line-height: 1;
  }
  .status-badge {
    font-size: 0.7rem;
    font-weight: 700;
    padding: 0.3rem 0.55rem;
    border-radius: 5px;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    line-height: 1;
  }
  .status-badge.policy { background: var(--policy-bg); color: var(--policy-fg); }
  .status-badge.infra  { background: var(--infra-bg);  color: var(--infra-fg);  }

  h1 {
    font-size: 1.4rem;
    font-weight: 600;
    color: var(--fg);
    margin: 1.25rem 0 0.75rem;
    letter-spacing: -0.015em;
  }

  .lede {
    color: var(--fg-muted);
    margin: 0 0 1.5rem;
    font-size: 0.95rem;
  }

  .next-steps {
    border: 1px solid var(--border);
    border-left: 3px solid var(--accent);
    padding: 0.875rem 1rem;
    margin: 1.5rem 0 0;
    border-radius: 0 8px 8px 0;
    background: var(--bg-card);
  }
  .next-steps-title {
    font-weight: 600;
    color: var(--fg);
    font-size: 0.82rem;
    margin: 0 0 0.25rem;
    letter-spacing: 0.01em;
  }
  .next-steps-body {
    margin: 0;
    color: var(--fg-muted);
    font-size: 0.875rem;
  }

  .request-id {
    margin-top: 1.5rem;
    padding: 0.875rem 1rem;
    background: var(--bg-soft);
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    flex-wrap: wrap;
  }
  .request-id-label {
    color: var(--fg-subtle);
    font-size: 0.72rem;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    font-weight: 600;
  }
  .request-id-value {
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    color: var(--fg);
    font-size: 0.85rem;
    font-weight: 500;
    user-select: all;
    -webkit-user-select: all;
  }

  details {
    margin-top: 1.25rem;
  }
  details summary {
    cursor: pointer;
    color: var(--fg-subtle);
    font-size: 0.75rem;
    font-weight: 500;
    user-select: none;
    list-style: none;
    padding: 0.25rem 0;
    letter-spacing: 0.02em;
  }
  details summary::-webkit-details-marker { display: none; }
  details summary::after {
    content: "+";
    margin-left: 0.4rem;
    color: var(--fg-subtle);
    display: inline-block;
    width: 0.6rem;
    text-align: center;
    transition: transform 0.15s ease;
  }
  details[open] summary::after { content: "−"; }

  .meta {
    margin: 0.5rem 0 0;
    padding: 0.875rem 1rem;
    background: var(--bg-soft);
    border-radius: 8px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    font-size: 0.78rem;
    color: var(--fg-muted);
  }
  .meta-row {
    padding: 3px 0;
    display: flex;
    gap: 0.75rem;
  }
  .meta-key {
    color: var(--fg-subtle);
    width: 5.5rem;
    flex-shrink: 0;
  }
  .meta-val {
    color: var(--fg);
    word-break: break-all;
  }

  footer {
    margin-top: 2rem;
    padding-top: 1.25rem;
    border-top: 1px solid var(--border);
    color: var(--fg-subtle);
    font-size: 0.72rem;
    text-align: center;
    line-height: 1.6;
  }

  @media (max-width: 480px) {
    main { padding: 1.5rem; border-radius: 10px; }
    .status-code { font-size: 2.25rem; }
    h1 { font-size: 1.25rem; }
  }
</style>
</head>
<body>
  <main aria-labelledby="title">
    <div class="brand">
      <span class="brand-mark" aria-hidden="true">N</span>
      <span>NexGuard</span>
    </div>

    <div class="status-row">
      <div class="status-code">{{.StatusCode}}</div>
      <div class="status-badge {{.Tone}}">{{.Badge}}</div>
    </div>

    <h1 id="title">{{.Title}}</h1>
    <p class="lede">{{.Lede}}</p>

    <div class="next-steps">
      <p class="next-steps-title">What to do next</p>
      <p class="next-steps-body">{{.NextSteps}}</p>
    </div>

    <div class="request-id" aria-label="Request ID for support">
      <span class="request-id-label">Request ID</span>
      <span class="request-id-value">{{.RequestID}}</span>
    </div>

    <details>
      <summary>Technical details</summary>
      <div class="meta">
        {{if .Hostname}}<div class="meta-row"><span class="meta-key">App</span><span class="meta-val">{{.Hostname}}</span></div>{{end}}
        <div class="meta-row"><span class="meta-key">Reason</span><span class="meta-val">{{.Reason}}</span></div>
        <div class="meta-row"><span class="meta-key">Time</span><span class="meta-val">{{.Time}}</span></div>
      </div>
    </details>

    <footer>
      Filtered by NexGuard · your organization's access gateway
    </footer>
  </main>
</body>
</html>`
