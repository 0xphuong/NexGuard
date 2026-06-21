//go:build !linux

package listener

import (
	"errors"
	"syscall"
)

// setTransparent is a no-op stub for non-Linux platforms. The proxy
// is deployed on Linux in production; macOS/Windows builds exist
// only for local dev (unit tests, IDE tooling). Listen() detects
// the stub and returns ErrTransparentUnsupported so the operator
// gets a clear error instead of a silently-broken listener.
func setTransparent(_, _ string, _ syscall.RawConn) error {
	return errors.New("listener: IP_TRANSPARENT requires Linux (TPROXY model not portable)")
}
