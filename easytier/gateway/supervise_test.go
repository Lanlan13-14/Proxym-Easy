//go:build linux

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The test executable is also a tiny fake core. Its -c wrapper exercises exec,
// argv, readiness, cancellation, reaping and unexpected exit without a real TUN.
func TestCoreHelper(t *testing.T) {
	if os.Getenv("EASYTIER_GATEWAY_TEST_HELPER") != "core" {
		return
	}
	var listener, mode string
	for i, arg := range os.Args {
		if arg == "--listeners" && i+1 < len(os.Args) {
			listener = strings.TrimPrefix(os.Args[i+1], "ws://")
		}
		if arg == "-c" && i+1 < len(os.Args) {
			mode = os.Args[i+1]
		}
	}
	if strings.HasSuffix(mode, "/exit") {
		os.Exit(7)
	}
	if strings.HasSuffix(mode, "/ignore-term") {
		signal.Ignore(syscall.SIGTERM, syscall.SIGINT)
	}
	ln, err := net.Listen("tcp4", listener)
	if err != nil {
		os.Exit(8)
	}
	defer ln.Close()
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		if strings.HasSuffix(mode, "/exit-after-ready") {
			conn.Close()
			os.Exit(9)
		}
		go func() {
			defer conn.Close()
			reader := bufio.NewReader(conn)
			r, err := http.ReadRequest(reader)
			if err != nil {
				return // readiness opens and closes without sending HTTP
			}
			io.WriteString(conn, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "+websocketAccept(r.Header.Get("Sec-WebSocket-Key"))+"\r\n\r\n")
			io.Copy(conn, reader)
		}()
	}
}

func coreFixture(t *testing.T, mode string) BootConfig {
	t.Helper()
	if os.Geteuid() != 0 {
		t.Skip("supervisor production setup requires root")
	}
	t.Setenv("EASYTIER_GATEWAY_TEST_HELPER", "core")
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	dir := privateDir(t)
	wrapper := filepath.Join(dir, "fake-core")
	// The shell is test-only. Production calls core_path directly, never a shell.
	script := "#!/bin/sh\nexec '" + strings.ReplaceAll(exe, "'", "'\\''") + "' -test.run=^TestCoreHelper$ -- \"$@\"\n"
	if err := os.WriteFile(wrapper, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	reserved, err := reserveCorePort(15888)
	if err != nil {
		t.Fatal(err)
	}
	port := reserved.Addr().(*net.TCPAddr).Port
	reserved.Close()
	return BootConfig{ListenPort: port, RPCPort: 15888, ControlPath: filepath.Join(dir, "control.sock"), Domain: testPayload().Domain,
		Payload: testPayload(), CorePath: wrapper, ConfigPath: filepath.Join(dir, mode), NoTUN: true}
}

func TestCoreArgsAndReservation(t *testing.T) {
	c := testBoot(t)
	want := []string{"-c", c.ConfigPath, "--listeners", "ws://127.0.0.1:32100", "--rpc-portal", "127.0.0.1:15888",
		"--console-log-level", "warn", "--file-log-level", "off"}
	if !reflect.DeepEqual(coreArgs(c, 32100), want) {
		t.Fatal("production core argv changed")
	}
	c.NoTUN = true
	if !reflect.DeepEqual(coreArgs(c, 32100), append(want, "--no-tun")) {
		t.Fatal("testing no-TUN flag not forwarded")
	}
	ln, err := reserveCorePort(15888, c.ListenPort)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	addr := ln.Addr().(*net.TCPAddr)
	if !addr.IP.Equal(net.IPv4(127, 0, 0, 1)) || addr.Port == 15888 || addr.Port == c.ListenPort {
		t.Fatal("bad internal reservation")
	}
	if duplicate, err := net.ListenTCP("tcp4", addr); err == nil {
		duplicate.Close()
		t.Fatal("internal port was not held reserved")
	}
}

func TestSupervisorReadinessCancelAndReap(t *testing.T) {
	c := coreFixture(t, "run")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- runGateway(ctx, c, io.Discard, io.Discard) }()
	waitFor(t, func() bool {
		conn, err := net.DialTimeout("unix", c.ControlPath, 50*time.Millisecond)
		if err != nil {
			return false
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(time.Second))
		io.WriteString(conn, "{\"command\":\"health\"}\n")
		var response map[string]any
		return json.NewDecoder(conn).Decode(&response) == nil && response["gateway_version"] == float64(3)
	})
	conn, err := net.DialTimeout("tcp4", fmt.Sprintf("127.0.0.1:%d", c.ListenPort), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	io.WriteString(conn, wsRequest())
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil || response.StatusCode != 101 {
		t.Fatal("supervised core handshake failed", err)
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("supervisor did not stop/reap promptly")
	}
	if _, err := os.Lstat(c.ControlPath); !os.IsNotExist(err) {
		t.Fatal("supervisor left its socket behind")
	}
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("supervisor left a stream open")
	}
}

func TestSupervisorUnexpectedExit(t *testing.T) {
	for _, mode := range []string{"exit", "exit-after-ready"} {
		t.Run(mode, func(t *testing.T) {
			c := coreFixture(t, mode)
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			if err := runGateway(ctx, c, io.Discard, io.Discard); err == nil {
				t.Fatal("core failure did not fail the gateway")
			}
			if _, err := os.Lstat(c.ControlPath); !os.IsNotExist(err) {
				t.Fatal("failed startup left a control socket")
			}
		})
	}
}

func TestCoreTerminationEscalatesToKill(t *testing.T) {
	c := coreFixture(t, "ignore-term")
	reserved, err := reserveCorePort(c.ListenPort, c.RPCPort)
	if err != nil {
		t.Fatal(err)
	}
	addr := reserved.Addr().(*net.TCPAddr)
	core, err := launchCore(c, reserved, io.Discard, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	defer core.stop()
	if err := waitCoreReady(context.Background(), core, addr); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	core.stop()
	if elapsed := time.Since(start); elapsed < coreStopTimeout || elapsed > coreStopTimeout+3*time.Second {
		t.Fatalf("termination escalation took %s", elapsed)
	}
	select {
	case <-core.done:
		if core.err == nil {
			t.Fatal("ignored-SIGTERM core was not killed")
		}
	default:
		t.Fatal("killed core was not reaped")
	}
}

func TestPeerCredRejectsNonRoot(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("requires root to drop subprocess credentials")
	}
	// Check the kernel helper directly, independent of filesystem mode checks.
	path := filepath.Join(privateDir(t), "peer.sock")
	os.Chmod(filepath.Dir(path), 0755)
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	os.Chmod(path, 0666)
	exe, _ := os.Executable()
	cmd := exec.Command(exe, "-test.run=^TestPeerHelper$")
	cmd.Env = append(os.Environ(), "EASYTIER_GATEWAY_PEER_PATH="+path)
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: 65534, Gid: 65534}}
	if err := cmd.Start(); err != nil {
		t.Skipf("credential drop is unavailable in this sandbox: %v", err)
	}
	defer cmd.Process.Kill()
	ln.SetDeadline(time.Now().Add(2 * time.Second))
	peer, err := ln.AcceptUnix()
	if err != nil {
		_ = cmd.Wait()
		t.Skip("sandbox cannot reach peer socket after credential drop")
	}
	defer peer.Close()
	if rootPeer(peer) {
		_ = cmd.Wait()
		t.Fatal("SO_PEERCRED trusted a non-root subprocess")
	}
	if err := cmd.Wait(); err != nil {
		t.Fatal(err)
	}
}

func TestPeerHelper(t *testing.T) {
	path := os.Getenv("EASYTIER_GATEWAY_PEER_PATH")
	if path == "" {
		return
	}
	conn, err := net.DialTimeout("unix", path, time.Second)
	if err != nil {
		os.Exit(1)
	}
	conn.Close()
}
