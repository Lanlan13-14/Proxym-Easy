package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

const (
	maxControlConnections = 8
	maxControlBytes       = 4096 // includes the required terminal newline
	controlTimeout        = 5 * time.Second
)

type Control struct {
	listener *net.UnixListener
	path     string
	owned    os.FileInfo
	gateway  *Gateway
	slots    chan struct{}
	mu       sync.Mutex
	closing  bool
	clients  map[*net.UnixConn]struct{}
	workers  sync.WaitGroup
}

// Refuse untrusted directories rather than creating a root socket in a
// world-writable location. The installer owns creating the existing 0700 tmp/.
func safeControlParent(path string) bool {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return false
	}
	parent := filepath.Dir(path)
	if info, err := os.Lstat(parent); err != nil || info.Mode().Perm()&0077 != 0 {
		return false
	}
	for {
		info, err := os.Lstat(parent)
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0022 != 0 {
			return false
		}
		if stat, ok := info.Sys().(*syscall.Stat_t); !ok || stat.Uid != uint32(os.Geteuid()) {
			return false
		}
		// The immediate private directory protects descendants from renames.
		// Ancestors may be sticky /tmp during isolated helper tests.
		if parent == "/" {
			return true
		}
		parent = filepath.Dir(parent)
		if parent == "/tmp" || parent == "/var/tmp" {
			info, err := os.Lstat(parent)
			if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
				return false
			}
			stat, ok := info.Sys().(*syscall.Stat_t)
			return ok && stat.Uid == uint32(os.Geteuid()) && (info.Mode().Perm()&0022 == 0 || info.Mode()&os.ModeSticky != 0)
		}
	}
}

func removeOwnedSocket(path string, owned os.FileInfo) {
	if owned == nil {
		return
	}
	current, err := os.Lstat(path)
	if err == nil && current.Mode()&os.ModeSocket != 0 && os.SameFile(owned, current) {
		_ = os.Remove(path)
	}
}

func prepareControlPath(path string) error {
	if !safeControlParent(path) {
		return errors.New("unsafe control socket directory")
	}
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || info.Mode()&os.ModeSocket == 0 || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("control path is not a safe socket")
	}
	conn, dialErr := net.DialTimeout("unix", path, time.Second)
	if dialErr == nil {
		conn.Close()
		return errors.New("control socket already running")
	}
	// Timeout, permission denial, and unknown errors are not proof of staleness.
	if !errors.Is(dialErr, syscall.ECONNREFUSED) {
		return errors.New("cannot verify stale control socket")
	}
	current, err := os.Lstat(path)
	if err != nil || !os.SameFile(info, current) || current.Mode()&os.ModeSocket == 0 {
		return errors.New("control socket changed during startup")
	}
	if err := os.Remove(path); err != nil {
		return errors.New("cannot remove stale control socket")
	}
	return nil
}

func newControl(path string, gateway *Gateway) (*Control, error) {
	if err := prepareControlPath(path); err != nil {
		return nil, err
	}
	// The parent is verified 0700 and root-owned before binding. No non-root
	// process can traverse it during bind/chmod, even if umask is permissive.
	// ListenUnix never replaces an existing inode, and automatic unlink is off.
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return nil, errors.New("cannot bind control socket")
	}
	listener.SetUnlinkOnClose(false)
	owned, err := os.Lstat(path)
	if err != nil {
		listener.Close()
		return nil, errors.New("cannot identify control socket")
	}
	if err := os.Chmod(path, 0600); err != nil {
		listener.Close()
		removeOwnedSocket(path, owned)
		return nil, errors.New("cannot protect control socket")
	}
	return &Control{listener: listener, path: path, owned: owned, gateway: gateway,
		slots: make(chan struct{}, maxControlConnections), clients: make(map[*net.UnixConn]struct{})}, nil
}

func (c *Control) serve() error {
	for {
		conn, err := c.listener.AcceptUnix()
		if err != nil {
			return err
		}
		select {
		case c.slots <- struct{}{}:
		default:
			conn.Close()
			continue
		}
		c.mu.Lock()
		if c.closing {
			c.mu.Unlock()
			<-c.slots
			conn.Close()
			return net.ErrClosed
		}
		c.clients[conn] = struct{}{}
		c.workers.Add(1)
		c.mu.Unlock()
		go func() {
			defer c.workers.Done()
			defer func() {
				conn.Close()
				c.mu.Lock()
				delete(c.clients, conn)
				c.mu.Unlock()
				<-c.slots
			}()
			c.handle(conn)
		}()
	}
}

func (c *Control) handle(conn *net.UnixConn) {
	conn.SetDeadline(time.Now().Add(controlTimeout))
	if !rootPeer(conn) {
		return
	}
	reader := bufio.NewReaderSize(conn, maxControlBytes)
	raw, err := reader.ReadSlice('\n')
	if err != nil || len(raw) > maxControlBytes {
		return
	}
	var request struct {
		Command string `json:"command"`
		Token   string `json:"token"`
	}
	if json.Unmarshal(raw, &request) != nil {
		return
	}
	response := map[string]any{"ok": true}
	switch request.Command {
	case "health":
		response["gateway_version"], response["port"] = gatewayVersion, c.gateway.port()
		response["domain"], response["instance_id"] = c.gateway.domain, c.gateway.instanceID
	case "issue":
		token, err := c.gateway.grant.issue()
		if err != nil {
			response = map[string]any{"ok": false}
		} else {
			response["token"], response["domain"], response["ttl"] = token, c.gateway.domain, int(joinTTL.Seconds())
		}
	case "status":
		response["status"] = c.gateway.grant.status(request.Token)
	case "revoke":
		response["status"] = c.gateway.grant.revoke(request.Token)
	default:
		response["ok"] = false
	}
	_ = json.NewEncoder(conn).Encode(response)
}

func (c *Control) close() {
	c.listener.Close()
	c.mu.Lock()
	c.closing = true
	for conn := range c.clients {
		conn.Close()
	}
	c.mu.Unlock()
	c.workers.Wait()
	removeOwnedSocket(c.path, c.owned)
}
