package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func fixtureControl(t *testing.T, g *Gateway) *Control {
	t.Helper()
	if runtime.GOOS != "linux" || os.Geteuid() != 0 {
		t.Skip("production control requires Linux root")
	}
	control, err := newControl(filepath.Join(privateDir(t), "control.sock"), g)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { defer close(done); _ = control.serve() }()
	t.Cleanup(func() { control.close(); <-done })
	return control
}

func controlCall(t *testing.T, c *Control, command, token string) map[string]any {
	t.Helper()
	conn, err := net.DialTimeout("unix", c.path, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	if err := json.NewEncoder(conn).Encode(map[string]any{"command": command, "token": token}); err != nil {
		t.Fatal(err)
	}
	var response map[string]any
	if err := json.NewDecoder(conn).Decode(&response); err != nil {
		t.Fatal(err)
	}
	return response
}

func TestControlProtocolPermissionsAndOwnedCleanup(t *testing.T) {
	g := fixtureGateway(t, nil)
	c := fixtureControl(t, g)
	info, err := os.Lstat(c.path)
	if err != nil || info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != 0600 {
		t.Fatal("control socket is not 0600")
	}
	health := controlCall(t, c, "health", "")
	if health["ok"] != true || health["gateway_version"] != float64(3) || health["port"] != float64(g.port()) ||
		health["domain"] != g.domain || health["instance_id"] != g.instanceID || len(health) != 5 {
		t.Fatalf("health contract mismatch: %#v", health)
	}
	issued := controlCall(t, c, "issue", "")
	token, ok := issued["token"].(string)
	if !ok || !lowerHex(token, 64) || issued["ttl"] != float64(900) || issued["domain"] != g.domain || len(issued) != 4 {
		t.Fatal("issue contract mismatch")
	}
	if controlCall(t, c, "status", token)["status"] != "active" || controlCall(t, c, "revoke", token)["status"] != "revoked" ||
		controlCall(t, c, "status", token)["status"] != "revoked" || controlCall(t, c, "status", "old")["status"] != "superseded" ||
		controlCall(t, c, "unknown", "")["ok"] != false {
		t.Fatal("control status/revoke contract mismatch")
	}
	for _, response := range []map[string]any{health, controlCall(t, c, "status", token)} {
		b, _ := json.Marshal(response)
		if strings.Contains(string(b), testPayload().Secret) || strings.Contains(string(b), token) {
			t.Fatal("control health/status leaked credential")
		}
	}
	c.close()
	if _, err := os.Lstat(c.path); !os.IsNotExist(err) {
		t.Fatal("owned control socket not removed")
	}
}

func TestControlRejectsUnsafeAndLivePaths(t *testing.T) {
	g := fixtureGateway(t, nil)
	c := fixtureControl(t, g)
	if other, err := newControl(c.path, g); err == nil {
		other.close()
		t.Fatal("live control socket was replaced")
	}
	dir := privateDir(t)
	regular := filepath.Join(dir, "regular")
	if err := os.WriteFile(regular, []byte("preserve"), 0600); err != nil {
		t.Fatal(err)
	}
	symlink := filepath.Join(dir, "symlink")
	if err := os.Symlink(regular, symlink); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{regular, symlink} {
		if other, err := newControl(path, g); err == nil {
			other.close()
			t.Fatal("unsafe existing path was replaced")
		}
	}
	data, _ := os.ReadFile(regular)
	if string(data) != "preserve" {
		t.Fatal("non-socket file modified")
	}
	unsafeDir := filepath.Join(dir, "world-writable")
	if err := os.Mkdir(unsafeDir, 0777); err != nil {
		t.Fatal(err)
	}
	os.Chmod(unsafeDir, 0777)
	if other, err := newControl(filepath.Join(unsafeDir, "control.sock"), g); err == nil {
		other.close()
		t.Fatal("world-writable control directory accepted")
	}
}

func TestControlReclaimsOnlyStaleAndKeepsReplacement(t *testing.T) {
	g := fixtureGateway(t, nil)
	if runtime.GOOS != "linux" || os.Geteuid() != 0 {
		t.Skip("requires Linux root")
	}
	path := filepath.Join(privateDir(t), "control.sock")
	stale, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	stale.SetUnlinkOnClose(false)
	stale.Close()
	c, err := newControl(path, g)
	if err != nil {
		t.Fatal("stale socket not reclaimed", err)
	}
	defer c.close()
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	replacement, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer replacement.Close()
	c.close()
	if _, err := os.Lstat(path); err != nil {
		t.Fatal("cleanup removed a replacement inode")
	}
}

func TestControlRequestBoundsAndConnectionLimit(t *testing.T) {
	g := fixtureGateway(t, nil)
	c := fixtureControl(t, g)
	for _, request := range []string{strings.Repeat("x", maxControlBytes) + "\n", "{bad}\n", `{"command":1}` + "\n"} {
		conn, err := net.DialTimeout("unix", c.path, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		conn.SetDeadline(time.Now().Add(time.Second))
		io.WriteString(conn, request)
		if b, _ := io.ReadAll(conn); len(b) != 0 {
			t.Fatal("malformed/oversized control request returned data")
		}
		conn.Close()
	}
	waitFor(t, func() bool { return len(c.slots) == 0 })
	var clients []net.Conn
	defer func() {
		for _, conn := range clients {
			conn.Close()
		}
	}()
	for i := 0; i < maxControlConnections; i++ {
		conn, err := net.DialTimeout("unix", c.path, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		clients = append(clients, conn)
	}
	waitFor(t, func() bool { return len(c.slots) == maxControlConnections })
	extra, err := net.DialTimeout("unix", c.path, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer extra.Close()
	extra.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := bufio.NewReader(extra).ReadByte(); err == nil {
		t.Fatal("control concurrency limit not enforced")
	} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("control excess client hung instead of closing")
	}
	c.close() // pending 5-second requests must close immediately on shutdown
	for _, conn := range clients {
		conn.SetReadDeadline(time.Now().Add(time.Second))
		if _, err := conn.Read(make([]byte, 1)); err == nil {
			t.Fatal("pending control client survived shutdown")
		}
	}
}
