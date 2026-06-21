package listener

import (
	"context"
	"strings"
	"testing"

	"github.com/0xphuong/NexGuard/proxy/internal/cert"
)

// Listen has Linux-only semantics (IP_TRANSPARENT). On macOS dev
// machines the setsockopt errors out — we assert the error path
// surfaces cleanly with the platform-specific message rather than
// a panic or a silently-broken listener.

func TestListen_RequiresListenAddr(t *testing.T) {
	if _, err := Listen(context.Background(), Config{Certificates: &cert.Holder{}}); err == nil {
		t.Fatal("expected error on empty ListenAddr")
	}
}

func TestListen_RequiresCertHolder(t *testing.T) {
	if _, err := Listen(context.Background(), Config{ListenAddr: "127.0.0.1:0"}); err == nil {
		t.Fatal("expected error on nil Certificates holder")
	}
}

// On Linux this test would need NET_ADMIN (or root) to set
// IP_TRANSPARENT. We assert ONLY the error message shape on
// non-Linux dev hosts; on Linux this test is skipped because the
// permission requirement varies per CI environment.
func TestListen_NonLinuxErrorsCleanly(t *testing.T) {
	_, err := Listen(context.Background(), Config{
		ListenAddr:   "127.0.0.1:0",
		Certificates: &cert.Holder{},
	})

	// Either we're on Linux (where setsockopt fails on a normal user
	// account with EPERM) or non-Linux (where the stub returns a
	// "requires Linux" error). Both error paths must include
	// "listener:" so log lines are greppable.
	if err == nil {
		t.Skip("listen unexpectedly succeeded — running as root? Skipping coverage assertion.")
	}
	if !strings.Contains(err.Error(), "listener") {
		t.Errorf("error string should be prefixed for grep, got %q", err.Error())
	}
}
