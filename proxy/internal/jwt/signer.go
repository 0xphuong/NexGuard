// Package jwt produces RS256-signed JWTs for the
// X-NexGuard-Identity-Jwt header on every L7 proxy request (ADR-010,
// task D-8).
//
// We sign with stdlib `crypto/rsa` + `crypto/sha256` to avoid pulling
// in a third-party JWT library — the security-review burden of
// keeping a dep up to date isn't worth the ~80 LOC saved.
//
// The signed payload format is a JWS Compact Serialization
// (RFC 7515) using RS256, header carrying the active key's `kid` so
// any verifier can resolve the matching public key from the JWKS
// endpoint.
package jwt

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"sync/atomic"
	"time"
)

// DefaultTTL matches the FzHttp.L7.JwtSigner default expires_in of
// 300 seconds. Short enough to bound replay risk if a header leaks,
// long enough to survive transient backend retries.
const DefaultTTL = 5 * time.Minute

// Signer wraps an RSA private key and an associated kid. A new
// Signer is cheap to allocate; the proxy keeps one at a time and
// atomically swaps it on every bundle reload.
type Signer struct {
	kid string
	key *rsa.PrivateKey
}

// Claims is the payload the proxy injects into
// X-NexGuard-Identity-Jwt. Mirrors what the backend's auth filters
// expect — see ADR-010.
type Claims struct {
	UserID        string   `json:"user_id"`
	Email         string   `json:"email"`
	Groups        []string `json:"groups,omitempty"`
	MFAAgeSeconds *int     `json:"mfa_age_seconds,omitempty"`
	IssuedAt      int64    `json:"iat"`
	ExpiresAt     int64    `json:"exp"`
}

// FromPEM parses an RSA private key (PKCS#1 "RSA PRIVATE KEY" or
// PKCS#8 unencrypted) and returns a Signer pinned to the given kid.
func FromPEM(kid string, pemBytes []byte) (*Signer, error) {
	if kid == "" {
		return nil, errors.New("jwt: kid is required")
	}

	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("jwt: no PEM block found in input")
	}

	var key *rsa.PrivateKey

	switch block.Type {
	case "RSA PRIVATE KEY":
		k, err := x509.ParsePKCS1PrivateKey(block.Bytes)
		if err != nil {
			return nil, fmt.Errorf("jwt: parse PKCS#1: %w", err)
		}
		key = k

	case "PRIVATE KEY":
		parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
		if err != nil {
			return nil, fmt.Errorf("jwt: parse PKCS#8: %w", err)
		}
		rsaKey, ok := parsed.(*rsa.PrivateKey)
		if !ok {
			return nil, fmt.Errorf("jwt: PKCS#8 key is not RSA (got %T)", parsed)
		}
		key = rsaKey

	default:
		return nil, fmt.Errorf("jwt: unsupported PEM block type %q", block.Type)
	}

	return &Signer{kid: kid, key: key}, nil
}

// Kid returns the key id the signer's signatures will carry.
func (s *Signer) Kid() string { return s.kid }

// Sign produces a JWS Compact Serialization (`header.payload.sig`)
// over the given claims with RS256. `iat` and `exp` are stamped here
// — callers should leave them zero in the input.
func (s *Signer) Sign(claims Claims, ttl time.Duration) (string, error) {
	if ttl == 0 {
		ttl = DefaultTTL
	}
	now := time.Now().Unix()
	claims.IssuedAt = now
	claims.ExpiresAt = now + int64(ttl.Seconds())

	headerJSON, err := json.Marshal(struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
		Typ string `json:"typ"`
	}{
		Alg: "RS256",
		Kid: s.kid,
		Typ: "JWT",
	})
	if err != nil {
		return "", fmt.Errorf("jwt: encode header: %w", err)
	}

	payloadJSON, err := json.Marshal(claims)
	if err != nil {
		return "", fmt.Errorf("jwt: encode payload: %w", err)
	}

	signingInput := b64(headerJSON) + "." + b64(payloadJSON)

	hashed := sha256.Sum256([]byte(signingInput))
	sigBytes, err := rsa.SignPKCS1v15(rand.Reader, s.key, crypto.SHA256, hashed[:])
	if err != nil {
		return "", fmt.Errorf("jwt: sign: %w", err)
	}

	return signingInput + "." + b64(sigBytes), nil
}

// SignerHolder is a goroutine-safe atomic slot for a *Signer. The
// proxy stores the active signer here and swaps it on every bundle
// pivot — request handlers `Load` without locking.
type SignerHolder struct {
	v atomic.Pointer[Signer]
}

func (h *SignerHolder) Set(s *Signer) { h.v.Store(s) }
func (h *SignerHolder) Get() *Signer  { return h.v.Load() }

// b64 = base64url with no padding, per RFC 7515 §2.
func b64(b []byte) string {
	return base64.RawURLEncoding.EncodeToString(b)
}
