#!/usr/bin/env bash
#
# Generates the internal-CA + server-cert + proxy-cert trio used to
# mTLS-protect the L7 control plane (ADR-007, L7-D v3.0.0):
#
#   1. internal-ca.{pem,key}     — self-signed root, both sides trust
#   2. internal-server.{pem,key} — Caddy presents at :13443
#   3. proxy.{pem,key}           — proxy daemon presents as client
#
# Outputs land in $NEXGUARD_CERTS_DIR (default /var/nexguard/l7-certs/).
# The Caddy mTLS site loads (1) + (2); the proxy compose overlay
# mounts (3) into the container.
#
# Idempotent rotation:
#   * Re-running this script regenerates the proxy + server certs
#     ONLY (CA preserved). Old certs are archived under
#     $NEXGUARD_CERTS_DIR/archive/<timestamp>/ in case a recently-
#     issued JWT or in-flight TLS handshake needs to verify.
#   * Pass --reset-ca to rotate the CA too. Doing so invalidates
#     every previously-issued proxy cert; downstream Caddy needs a
#     restart afterward (`docker compose restart caddy`).
#
# Requires: openssl 1.1.1+ or 3.x (matches Alpine + Ubuntu 22.04+).

set -euo pipefail

CERTS_DIR=${NEXGUARD_CERTS_DIR:-/var/nexguard/l7-certs}
CA_KEY_BITS=4096
LEAF_KEY_BITS=2048
CA_VALIDITY_DAYS=3650   # 10 years — operator rotates explicitly via --reset-ca
LEAF_VALIDITY_DAYS=365  # 1 year — operator runs this script annually

# Numeric UID/GID the proxy container's `nonroot` user has —
# matches gcr.io/distroless/static-debian12:nonroot. Override if
# you build a custom proxy image with a different uid.
PROXY_UID=${NEXGUARD_PROXY_UID:-65532}
PROXY_GID=${NEXGUARD_PROXY_GID:-65532}

# CN values are not security-critical (CA validates by signature, not
# CN); they're just human-readable in cert dumps.
CA_SUBJ="/CN=NexGuard L7 Internal CA/O=NexGuard"
SERVER_SUBJ="/CN=nexguard-internal/O=NexGuard"
PROXY_SUBJ="/CN=nexguard-proxy/O=NexGuard"

reset_ca=0
for arg in "$@"; do
  case "$arg" in
    --reset-ca) reset_ca=1 ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$CERTS_DIR" "$CERTS_DIR/archive"
cd "$CERTS_DIR"

archive_existing() {
  local files=("$@")
  local stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  local dest="$CERTS_DIR/archive/$stamp"
  mkdir -p "$dest"
  for f in "${files[@]}"; do
    if [[ -e "$f" ]]; then
      mv "$f" "$dest/"
    fi
  done
  echo "archived existing certs to $dest"
}

# ── CA ────────────────────────────────────────────────────────────

if [[ $reset_ca -eq 1 || ! -e internal-ca.pem ]]; then
  if [[ -e internal-ca.pem ]]; then
    archive_existing internal-ca.pem internal-ca.key
  fi
  echo "[ca] generating new ${CA_KEY_BITS}-bit RSA root"
  openssl genrsa -out internal-ca.key "$CA_KEY_BITS" 2>/dev/null
  openssl req -new -x509 -nodes \
    -key internal-ca.key \
    -days "$CA_VALIDITY_DAYS" \
    -subj "$CA_SUBJ" \
    -out internal-ca.pem
  chmod 600 internal-ca.key
  echo "[ca] internal-ca.pem (valid ${CA_VALIDITY_DAYS}d)"
else
  echo "[ca] reusing existing internal-ca.pem (use --reset-ca to rotate)"
fi

# ── Server cert (Caddy presents at :13443) ────────────────────────

archive_existing internal-server.pem internal-server.key

echo "[server] generating ${LEAF_KEY_BITS}-bit RSA + signing"
openssl genrsa -out internal-server.key "$LEAF_KEY_BITS" 2>/dev/null
# SANs:
#   * DNS:nexguard-internal — proxy uses this when reaching Caddy from
#     inside the nexguard container's net namespace (via the bridge
#     gateway, since `extra_hosts` is rejected with network_mode:service).
#   * DNS:localhost + IP:127.0.0.1 — operator curl from host (network_mode: host on Caddy).
#   * IP:172.25.0.1 — Docker bridge gateway as seen from inside nexguard
#     container. Matches the default nexguard-network subnet 172.25.0.0/16.
#     Override SERVER_EXTRA_SAN if your bridge gateway differs.
SERVER_SAN=${SERVER_EXTRA_SAN:-"DNS:nexguard-internal,DNS:localhost,IP:127.0.0.1,IP:172.25.0.1"}

openssl req -new -nodes \
  -key internal-server.key \
  -subj "$SERVER_SUBJ" \
  -addext "subjectAltName=${SERVER_SAN}" \
  -out internal-server.csr

openssl x509 -req \
  -in internal-server.csr \
  -CA internal-ca.pem -CAkey internal-ca.key \
  -CAcreateserial \
  -days "$LEAF_VALIDITY_DAYS" \
  -extfile <(printf "subjectAltName=%s\nextendedKeyUsage=serverAuth\n" "$SERVER_SAN") \
  -out internal-server.pem 2>/dev/null

rm -f internal-server.csr
chmod 600 internal-server.key

# ── Proxy client cert ─────────────────────────────────────────────

archive_existing proxy.pem proxy.key

echo "[proxy] generating ${LEAF_KEY_BITS}-bit RSA + signing"
openssl genrsa -out proxy.key "$LEAF_KEY_BITS" 2>/dev/null
openssl req -new -nodes \
  -key proxy.key \
  -subj "$PROXY_SUBJ" \
  -out proxy.csr

openssl x509 -req \
  -in proxy.csr \
  -CA internal-ca.pem -CAkey internal-ca.key \
  -CAcreateserial \
  -days "$LEAF_VALIDITY_DAYS" \
  -extfile <(printf "extendedKeyUsage=clientAuth\n") \
  -out proxy.pem 2>/dev/null

rm -f proxy.csr

# The proxy container runs as a non-root user (uid 65532 in the
# default distroless image). Make the cert + key readable by that
# uid via direct ownership; Docker bind mounts preserve numeric
# uid/gid into the container, where uid 65532 == `nonroot`.
chmod 640 proxy.key
chown "${PROXY_UID}:${PROXY_GID}" proxy.key proxy.pem 2>/dev/null || {
  echo "[proxy] chown to ${PROXY_UID}:${PROXY_GID} failed — proxy may not be able to read its cert" >&2
  echo "[proxy] falling back to chmod 644 on proxy.key (private key world-readable; ok IF the parent dir is locked down)" >&2
  chmod 644 proxy.key
}

# ── Summary ───────────────────────────────────────────────────────

cat <<EOF

[done] certs landed in $CERTS_DIR/
       internal-ca.pem         (root, trusted by Caddy + proxy)
       internal-server.{pem,key} (Caddy presents at :13443)
       proxy.{pem,key}         (proxy daemon presents as client)

Next steps:
  1. Restart Caddy so it reloads the new server cert + CA bundle:
       docker compose -f docker-compose.prod.yml restart caddy
  2. Restart the proxy daemon so it reloads its client cert:
       docker compose -f docker-compose.proxy.yml restart proxy
  3. Verify mTLS:
       curl --cacert $CERTS_DIR/internal-ca.pem \\
            --cert   $CERTS_DIR/proxy.pem \\
            --key    $CERTS_DIR/proxy.key \\
            https://127.0.0.1:13443/internal/bundle.json | jq .bundle_version
EOF
