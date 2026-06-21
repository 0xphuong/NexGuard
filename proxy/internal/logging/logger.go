// Package logging is a thin wrapper around log/slog with the
// proxy's house format (JSON, RFC3339Nano timestamps, level + msg
// + structured key=val attrs).
package logging

import (
	"log/slog"
	"os"
)

// New returns a *slog.Logger emitting JSON to stderr. Level is taken
// from the NEXGUARD_PROXY_LOG_LEVEL env var (debug|info|warn|error),
// defaulting to info.
func New() *slog.Logger {
	lvl := parseLevel(os.Getenv("NEXGUARD_PROXY_LOG_LEVEL"))
	h := slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{
		Level: lvl,
	})
	return slog.New(h)
}

func parseLevel(s string) slog.Level {
	switch s {
	case "debug":
		return slog.LevelDebug
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
