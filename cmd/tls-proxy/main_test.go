package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writePair(t *testing.T, dir, cn string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: cn},
		DNSNames:     []string{cn},
		NotBefore:    time.Now().Add(-time.Minute),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	if err := os.WriteFile(filepath.Join(dir, "tls.crt"), certPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "tls.key"), keyPEM, 0o600); err != nil {
		t.Fatal(err)
	}
}

func servedCN(t *testing.T, addr string) string {
	t.Helper()
	c, err := tls.Dial("tcp", addr, &tls.Config{InsecureSkipVerify: true})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	return c.ConnectionState().PeerCertificates[0].Subject.CommonName
}

func TestForwardAndReload(t *testing.T) {
	dir := t.TempDir()
	writePair(t, dir, "one.test")

	// An echo server standing in for sshd: it answers after the client's
	// half-close, which forward must pass on.
	backend, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	go func() {
		for {
			c, err := backend.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				data, _ := io.ReadAll(c)
				_, _ = c.Write(data)
			}()
		}
	}()

	store, err := newCertStore(filepath.Join(dir, "tls.crt"), filepath.Join(dir, "tls.key"))
	if err != nil {
		t.Fatal(err)
	}
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{GetCertificate: store.get})
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go serve(ln, backend.Addr().String())

	c, err := tls.Dial("tcp", ln.Addr().String(), &tls.Config{InsecureSkipVerify: true})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	if err := c.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(c)
	c.Close()
	if err != nil || string(got) != "ping" {
		t.Fatalf("echo through the proxy: %q, %v", got, err)
	}

	if cn := servedCN(t, ln.Addr().String()); cn != "one.test" {
		t.Fatalf("served %s, want one.test", cn)
	}

	// A half-written pair keeps the current certificate.
	if err := os.WriteFile(filepath.Join(dir, "tls.key"), []byte("partial"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.reload(); err == nil {
		t.Fatal("reload accepted a broken key")
	}
	if cn := servedCN(t, ln.Addr().String()); cn != "one.test" {
		t.Fatalf("served %s after a broken update, want one.test", cn)
	}

	writePair(t, dir, "two.test")
	if changed, err := store.reload(); err != nil || !changed {
		t.Fatalf("reload: changed=%v, %v", changed, err)
	}
	if cn := servedCN(t, ln.Addr().String()); cn != "two.test" {
		t.Fatalf("served %s after renewal, want two.test", cn)
	}
}
