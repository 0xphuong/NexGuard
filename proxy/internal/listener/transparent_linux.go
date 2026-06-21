//go:build linux

package listener

import (
	"fmt"
	"syscall"
)

// setTransparent sets IP_TRANSPARENT on the socket file descriptor.
// Lets the kernel deliver packets destined for OTHER addresses (the
// VIPs) to this listener, which is the half of TPROXY userspace
// needs to do — the other half (`tproxy to 127.0.0.1:8443` + fwmark
// route) is set up by fz_wall at the nftables/iproute2 layer
// (L7-C C-1/C-3).
//
// Note: SO_REUSEADDR is also set so a restart of the proxy doesn't
// fail with "address in use" on the wildcard inherit; Go's default
// behavior already enables it for tcp listeners, but we re-affirm
// here defensively.
func setTransparent(network, _ string, c syscall.RawConn) error {
	var setErr error
	err := c.Control(func(fd uintptr) {
		// IP_TRANSPARENT is per-protocol-family, so we must use
		// IPPROTO_IP for IPv4 listeners (and IPPROTO_IPV6 for IPv6
		// once dual-stack lands in v3.0.x). The umbrella in v3.0.0
		// is IPv4-only per ADR-014.
		if err := syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_TRANSPARENT, 1); err != nil {
			setErr = fmt.Errorf("listener: IP_TRANSPARENT setsockopt: %w", err)
			return
		}
	})
	if err != nil {
		return err
	}
	return setErr
}
