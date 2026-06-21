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
	"strings"
	"testing"
	"time"
)

// genTestPEM creates an in-memory RSA key in PKCS#1 PEM form. We
// intentionally do NOT pull in a fixture file — each test gets a
// fresh key, so a leak in CI output can't be reused.
func genTestPEM(t *testing.T, bits int, format string) (kid string, pemBytes []byte, public *rsa.PublicKey) {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, bits)
	if err != nil {
		t.Fatal(err)
	}

	var block *pem.Block
	switch format {
	case "pkcs1":
		block = &pem.Block{
			Type:  "RSA PRIVATE KEY",
			Bytes: x509.MarshalPKCS1PrivateKey(key),
		}
	case "pkcs8":
		b, err := x509.MarshalPKCS8PrivateKey(key)
		if err != nil {
			t.Fatal(err)
		}
		block = &pem.Block{Type: "PRIVATE KEY", Bytes: b}
	default:
		t.Fatalf("unknown format %q", format)
	}

	return "kid-test-1", pem.EncodeToMemory(block), &key.PublicKey
}

func TestFromPEM_AcceptsPKCS1(t *testing.T) {
	kid, pemBytes, _ := genTestPEM(t, 2048, "pkcs1")
	s, err := FromPEM(kid, pemBytes)
	if err != nil {
		t.Fatalf("FromPEM: %v", err)
	}
	if s.Kid() != kid {
		t.Errorf("kid: want %q, got %q", kid, s.Kid())
	}
}

func TestFromPEM_AcceptsPKCS8(t *testing.T) {
	kid, pemBytes, _ := genTestPEM(t, 2048, "pkcs8")
	s, err := FromPEM(kid, pemBytes)
	if err != nil {
		t.Fatalf("FromPEM: %v", err)
	}
	if s.Kid() != kid {
		t.Errorf("kid mismatch")
	}
}

func TestFromPEM_RejectsEmptyKid(t *testing.T) {
	_, pemBytes, _ := genTestPEM(t, 2048, "pkcs1")
	if _, err := FromPEM("", pemBytes); err == nil {
		t.Fatal("expected error on empty kid")
	}
}

func TestFromPEM_RejectsNonPEM(t *testing.T) {
	if _, err := FromPEM("k", []byte("not a pem")); err == nil {
		t.Fatal("expected error on non-PEM input")
	}
}

func TestSign_RoundTrip_PreservesClaims(t *testing.T) {
	kid, pemBytes, pub := genTestPEM(t, 2048, "pkcs1")
	s, err := FromPEM(kid, pemBytes)
	if err != nil {
		t.Fatal(err)
	}

	mfaAge := 142
	c := Claims{
		UserID:        "u-1",
		Email:         "alice@example.com",
		Groups:        []string{"devops"},
		MFAAgeSeconds: &mfaAge,
	}

	jws, err := s.Sign(c, 60*time.Second)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	parts := strings.Split(jws, ".")
	if len(parts) != 3 {
		t.Fatalf("expected 3 parts in compact JWS, got %d", len(parts))
	}

	// Header carries our kid + RS256.
	header := decodeJSONPart(t, parts[0])
	if header["alg"] != "RS256" {
		t.Errorf("alg: want RS256, got %v", header["alg"])
	}
	if header["kid"] != kid {
		t.Errorf("kid: want %q, got %v", kid, header["kid"])
	}

	// Payload preserves caller claims + iat/exp.
	payload := decodeJSONPart(t, parts[1])
	if payload["user_id"] != "u-1" {
		t.Errorf("user_id: got %v", payload["user_id"])
	}
	if payload["email"] != "alice@example.com" {
		t.Errorf("email: got %v", payload["email"])
	}
	iat, exp := payload["iat"].(float64), payload["exp"].(float64)
	if exp-iat != 60 {
		t.Errorf("exp - iat: want 60, got %v", exp-iat)
	}

	// Signature verifies under the matching public key.
	sigBytes, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatalf("decode signature: %v", err)
	}
	signingInput := parts[0] + "." + parts[1]
	hashed := sha256.Sum256([]byte(signingInput))

	if err := rsa.VerifyPKCS1v15(pub, crypto.SHA256, hashed[:], sigBytes); err != nil {
		t.Errorf("signature did not verify: %v", err)
	}
}

func TestSign_DefaultTTL_IsFiveMinutes(t *testing.T) {
	kid, pemBytes, _ := genTestPEM(t, 2048, "pkcs1")
	s, _ := FromPEM(kid, pemBytes)

	jws, err := s.Sign(Claims{UserID: "u"}, 0)
	if err != nil {
		t.Fatal(err)
	}

	parts := strings.Split(jws, ".")
	payload := decodeJSONPart(t, parts[1])
	iat, exp := payload["iat"].(float64), payload["exp"].(float64)
	if exp-iat != float64(DefaultTTL.Seconds()) {
		t.Errorf("default TTL: want %v, got %v", DefaultTTL.Seconds(), exp-iat)
	}
}

func TestSignerHolder_AtomicSwap(t *testing.T) {
	var h SignerHolder
	if h.Get() != nil {
		t.Error("zero-value holder should return nil")
	}

	_, pem1, _ := genTestPEM(t, 2048, "pkcs1")
	s1, _ := FromPEM("k1", pem1)
	h.Set(s1)

	if h.Get().Kid() != "k1" {
		t.Errorf("after Set: kid mismatch")
	}

	_, pem2, _ := genTestPEM(t, 2048, "pkcs1")
	s2, _ := FromPEM("k2", pem2)
	h.Set(s2)

	if h.Get().Kid() != "k2" {
		t.Errorf("after swap: kid mismatch")
	}
}

func decodeJSONPart(t *testing.T, part string) map[string]any {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(part)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	return out
}
