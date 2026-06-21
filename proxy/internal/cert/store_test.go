package cert

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"testing"
	"time"

	"github.com/0xphuong/NexGuard/proxy/internal/bundle"
)

// genCertPEM mints a self-signed ECDSA cert + key for a hostname.
// ECDSA keeps tests fast — RSA-2048 generation would dwarf the
// rest of the suite.
func genCertPEM(t *testing.T, host string) (certPEM, keyPEM string) {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: host},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		DNSNames:     []string{host},
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}

	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM = string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))

	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM = string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}))
	return
}

func TestFromBundle_MultipleApps(t *testing.T) {
	c1, k1 := genCertPEM(t, "wiki.internal")
	c2, k2 := genCertPEM(t, "jenkins.internal")

	b := &bundle.Bundle{Apps: []bundle.App{
		{ID: "1", Hostname: "wiki.internal", TLSMode: "terminate", CertPEM: c1, KeyPEM: k1},
		{ID: "2", Hostname: "jenkins.internal", TLSMode: "terminate", CertPEM: c2, KeyPEM: k2},
	}}

	s, err := FromBundle(b)
	if err != nil {
		t.Fatal(err)
	}
	if s.Size() != 2 {
		t.Errorf("Size: want 2, got %d", s.Size())
	}
	if _, err := s.Get("wiki.internal"); err != nil {
		t.Error("expected wiki.internal in store")
	}
}

func TestGet_UnknownHostReturnsErr(t *testing.T) {
	s, _ := FromBundle(&bundle.Bundle{})
	if _, err := s.Get("nope.example"); !errors.Is(err, ErrUnknownHost) {
		t.Errorf("want ErrUnknownHost, got %v", err)
	}
}

func TestFromBundle_SkipsPassthroughApps(t *testing.T) {
	c, k := genCertPEM(t, "raw.internal")
	b := &bundle.Bundle{Apps: []bundle.App{
		{ID: "raw", Hostname: "raw.internal", TLSMode: "passthrough", CertPEM: c, KeyPEM: k},
	}}

	s, err := FromBundle(b)
	if err != nil {
		t.Fatal(err)
	}
	if s.Size() != 0 {
		t.Errorf("passthrough apps should not load into the SNI store; got Size=%d", s.Size())
	}
}

func TestFromBundle_SkipsAppsWithoutCert(t *testing.T) {
	b := &bundle.Bundle{Apps: []bundle.App{
		{ID: "pending", Hostname: "pending.internal", TLSMode: "terminate", CertPEM: "", KeyPEM: ""},
	}}
	s, err := FromBundle(b)
	if err != nil {
		t.Fatal(err)
	}
	if s.Size() != 0 {
		t.Errorf("apps without cert material should be skipped; got Size=%d", s.Size())
	}
}

func TestFromBundle_FailsOnUnparseableCert(t *testing.T) {
	b := &bundle.Bundle{Apps: []bundle.App{
		{ID: "broken", Hostname: "broken.internal", TLSMode: "terminate",
			CertPEM: "not a pem", KeyPEM: "not a pem"},
	}}
	if _, err := FromBundle(b); err == nil {
		t.Fatal("expected parse error on unparseable PEM")
	}
}

func TestHolder_GetCertificate(t *testing.T) {
	c1, k1 := genCertPEM(t, "wiki.internal")
	s, _ := FromBundle(&bundle.Bundle{Apps: []bundle.App{
		{ID: "1", Hostname: "wiki.internal", TLSMode: "terminate", CertPEM: c1, KeyPEM: k1},
	}})

	var h Holder
	h.Set(s)

	got, err := h.GetCertificate(&tls.ClientHelloInfo{ServerName: "wiki.internal"})
	if err != nil {
		t.Fatalf("GetCertificate: %v", err)
	}
	if got == nil {
		t.Fatal("nil cert returned")
	}

	if _, err := h.GetCertificate(&tls.ClientHelloInfo{ServerName: "missing.internal"}); err == nil {
		t.Error("expected unknown-host error")
	}
}

func TestHolder_GetCertificateBeforeLoad(t *testing.T) {
	var h Holder
	if _, err := h.GetCertificate(&tls.ClientHelloInfo{ServerName: "x"}); err == nil {
		t.Error("expected error when holder hasn't been Set yet")
	}
}
