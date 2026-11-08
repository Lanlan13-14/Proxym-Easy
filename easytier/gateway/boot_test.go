package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testPayload() JoinPayload {
	return JoinPayload{Format: "easytier-cf-join-v1", Domain: "akamai-sg.neverquit.fun", Network: "test-network",
		Secret: strings.Repeat("fixture-only-", 6), Subnet: "10.20.0.0/24", ServerName: "vps"}
}

func testBoot(t *testing.T) BootConfig {
	t.Helper()
	dir := t.TempDir()
	return BootConfig{ListenPort: 22333, RPCPort: 15888, ControlPath: filepath.Join(dir, "control.sock"),
		CorePath: filepath.Join(dir, "core"), ConfigPath: filepath.Join(dir, "config.toml"),
		Domain: testPayload().Domain, Payload: testPayload()}
}

func fixtureGateway(t *testing.T, upstream *net.TCPAddr) *Gateway {
	t.Helper()
	if upstream == nil {
		upstream = &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1}
	}
	grant, err := newJoinGrant(testPayload())
	if err != nil {
		t.Fatal(err)
	}
	g, err := newGateway(0, upstream, testPayload().Domain, grant)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { defer close(done); _ = g.server.Serve(g.listener) }()
	t.Cleanup(func() { g.close(); <-done })
	return g
}

func issueToken(t *testing.T, g *Gateway) string {
	t.Helper()
	token, err := g.grant.issue()
	if err != nil {
		t.Fatal(err)
	}
	return token
}

func gatewayRequest(t *testing.T, g *Gateway, method, path string, mark bool) (int, []byte, http.Header) {
	t.Helper()
	request, err := http.NewRequest(method, "http://"+g.listener.Addr().String()+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	if mark {
		request.Header.Set("X-EasyTier-Join", "1")
	}
	transport := &http.Transport{Proxy: nil, DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 3 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	return response.StatusCode, body, response.Header
}

func privateDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "etgw-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func waitFor(t *testing.T, f func() bool) {
	t.Helper()
	deadline := time.NewTimer(3 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(5 * time.Millisecond)
	defer tick.Stop()
	for !f() {
		select {
		case <-deadline.C:
			t.Fatal("condition did not become true")
		case <-tick.C:
		}
	}
}

func TestVersionAndSafeErrors(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if gatewayMain([]string{"--version"}, &stdout, &stderr) != 0 || stdout.String() != "easytier-gateway 1.0.0\n" || stderr.Len() != 0 {
		t.Fatalf("version result: %q %q", stdout.String(), stderr.String())
	}
	stdout.Reset()
	if gatewayMain([]string{"--unknown=DO_NOT_ECHO"}, &stdout, &stderr) != 2 || strings.Contains(stderr.String(), "DO_NOT_ECHO") {
		t.Fatal("argument error leaked supplied data")
	}
}

func TestBootFD(t *testing.T) {
	cfg := testBoot(t)
	valid, _ := json.Marshal(cfg)
	for _, item := range []struct {
		name string
		raw  []byte
		ok   bool
	}{
		{"valid", valid, true},
		{"exact_limit", append(append([]byte(nil), valid...), bytes.Repeat([]byte(" "), maxBootBytes-len(valid))...), true},
		{"oversize", bytes.Repeat([]byte("x"), maxBootBytes+1), false},
		{"trailing", append(append([]byte(nil), valid...), []byte(" {}")...), false},
		{"unknown", []byte(`{"unexpected":"DO_NOT_ECHO"}`), false},
		{"array", []byte(`[]`), false},
		{"null", []byte(`null`), false},
	} {
		t.Run(item.name, func(t *testing.T) {
			file, err := os.CreateTemp(t.TempDir(), "boot")
			if err != nil {
				t.Fatal(err)
			}
			defer file.Close()
			if _, err := file.Write(item.raw); err != nil {
				t.Fatal(err)
			}
			if _, err := file.Seek(0, io.SeekStart); err != nil {
				t.Fatal(err)
			}
			decoded, err := readBoot(int(file.Fd()))
			if (err == nil) != item.ok {
				t.Fatalf("decode success=%v want=%v", err == nil, item.ok)
			}
			if err == nil && decoded.Payload != cfg.Payload {
				t.Fatal("client payload changed")
			}
			if _, err := file.Read(make([]byte, 1)); err == nil {
				t.Fatal("boot descriptor was not closed")
			}
		})
	}
	if _, err := readBoot(0); err == nil {
		t.Fatal("stdin must not supply configuration")
	}
}

func TestBootValidation(t *testing.T) {
	base := testBoot(t)
	for _, mutate := range []func(*BootConfig){
		func(c *BootConfig) { c.ListenPort = 0 },
		func(c *BootConfig) { c.RPCPort = c.ListenPort },
		func(c *BootConfig) { c.ControlPath = "relative" },
		func(c *BootConfig) { c.Domain = "http://example.com" },
		func(c *BootConfig) { c.Payload.Domain = "other.example.com" },
		func(c *BootConfig) { c.Payload.Format = "v2" },
		func(c *BootConfig) { c.Payload.Secret = "short" },
		func(c *BootConfig) { c.Payload.Subnet = "10.20.0.1/24" },
		func(c *BootConfig) { c.Payload.Subnet = "8.8.8.0/24" },
		func(c *BootConfig) { c.Payload.Subnet = "fd00::/24" },
		func(c *BootConfig) { c.Payload.Network = "bad/name" },
	} {
		cfg := base
		mutate(&cfg)
		if cfg.validate() == nil {
			t.Fatal("invalid boot configuration accepted")
		}
	}
}
