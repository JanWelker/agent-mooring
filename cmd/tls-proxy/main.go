// Command tls-proxy is the TLS sidecar: it terminates TLS on :2222 with the
// session's certificate and forwards each connection to sshd on loopback. It
// re-reads the certificate every TLS_RELOAD_INTERVAL, so a cert-manager
// renewal reaches the next handshake without a restart; open connections keep
// the certificate they started with.
package main

import (
	"bytes"
	"crypto/tls"
	"errors"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("tls-proxy: ")

	certFile := env("TLS_CERT", "/tls/tls.crt")
	keyFile := env("TLS_KEY", "/tls/tls.key")
	port := env("TLS_PORT", "2222")
	target := env("SSHD_ADDRESS", "127.0.0.1:2223")
	interval, err := strconv.Atoi(env("TLS_RELOAD_INTERVAL", "60"))
	if err != nil || interval < 1 {
		log.Fatalf("TLS_RELOAD_INTERVAL must be a positive number of seconds")
	}

	store, err := newCertStore(certFile, keyFile)
	if err != nil {
		log.Fatal(err)
	}
	go store.watch(time.Duration(interval) * time.Second)

	ln, err := tls.Listen("tcp", ":"+port, &tls.Config{
		GetCertificate: store.get,
		MinVersion:     tls.VersionTLS12,
	})
	if err != nil {
		log.Fatal(err)
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-stop
		os.Exit(0)
	}()

	serve(ln, target)
}

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// serve accepts until the listener fails. Handshake errors are not logged:
// every TCP probe is one.
func serve(ln net.Listener, target string) {
	for {
		c, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			log.Printf("accept: %v", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go forward(c, target)
	}
}

// forward completes the handshake, then copies both ways and passes a
// half-close on, as ssh expects. A probe or a failed handshake never reaches
// sshd.
func forward(c net.Conn, target string) {
	defer c.Close()
	if t, ok := c.(*tls.Conn); ok {
		_ = t.SetDeadline(time.Now().Add(10 * time.Second))
		if err := t.Handshake(); err != nil {
			return
		}
		_ = t.SetDeadline(time.Time{})
	}
	b, err := net.DialTimeout("tcp", target, 10*time.Second)
	if err != nil {
		log.Printf("dial %s: %v", target, err)
		return
	}
	defer b.Close()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(b, c)
		_ = b.(*net.TCPConn).CloseWrite()
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(c, b)
		if t, ok := c.(*tls.Conn); ok {
			_ = t.CloseWrite()
		}
	}()
	wg.Wait()
}

type certStore struct {
	certFile, keyFile string

	mu     sync.RWMutex
	cert   *tls.Certificate
	loaded []byte
}

func newCertStore(certFile, keyFile string) (*certStore, error) {
	s := &certStore{certFile: certFile, keyFile: keyFile}
	if _, err := s.reload(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *certStore) get(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cert, nil
}

// reload swaps in the files' certificate when they changed. A pair that does
// not parse, as during a Secret update, keeps the current one.
func (s *certStore) reload() (bool, error) {
	certPEM, err := os.ReadFile(s.certFile)
	if err != nil {
		return false, err
	}
	keyPEM, err := os.ReadFile(s.keyFile)
	if err != nil {
		return false, err
	}
	both := append(append([]byte{}, certPEM...), keyPEM...)
	s.mu.RLock()
	same := bytes.Equal(both, s.loaded)
	s.mu.RUnlock()
	if same {
		return false, nil
	}
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return false, err
	}
	s.mu.Lock()
	s.cert, s.loaded = &cert, both
	s.mu.Unlock()
	return true, nil
}

func (s *certStore) watch(every time.Duration) {
	for range time.Tick(every) {
		changed, err := s.reload()
		switch {
		case err != nil:
			log.Printf("certificate not reloaded: %v", err)
		case changed:
			log.Printf("certificate changed, serving the new one")
		}
	}
}
