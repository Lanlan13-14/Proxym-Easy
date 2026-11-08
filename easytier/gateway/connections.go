package main

import (
	"context"
	"errors"
	"net"
	"sync"
	"time"
)

// gateListener counts complete connection lifetimes (including hijacked streams),
// not just handshakes. Only the accept boundary is wrapped; relayTCP unwraps it.
type gateListener struct {
	*net.TCPListener
	slots chan struct{}
	owner *Gateway
}

type gateConn struct {
	*net.TCPConn
	once    sync.Once
	release func()
}

func (c *gateConn) Close() error {
	err := c.TCPConn.Close()
	c.once.Do(c.release)
	return err
}

func (l *gateListener) Accept() (net.Conn, error) {
	for {
		tcp, err := l.AcceptTCP()
		if err != nil {
			return nil, err
		}
		select {
		case l.slots <- struct{}{}:
		default:
			tcp.Close()
			continue
		}
		tcp.SetNoDelay(true)
		c := &gateConn{TCPConn: tcp}
		c.release = func() { <-l.slots; l.owner.untrack(c) }
		if !l.owner.track(c) {
			c.Close()
			return nil, net.ErrClosed
		}
		return c, nil
	}
}

func rawTCP(c net.Conn) (*net.TCPConn, bool) {
	switch c := c.(type) {
	case *net.TCPConn:
		return c, true
	case *gateConn:
		return c.TCPConn, true
	default:
		return nil, false
	}
}

func (g *Gateway) track(c net.Conn) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.stopping {
		return false
	}
	g.connections[c] = struct{}{}
	return true
}

func (g *Gateway) untrack(c net.Conn) {
	g.mu.Lock()
	delete(g.connections, c)
	g.mu.Unlock()
}

// beginRelay and closeStreams use the same lock, so Wait cannot race with Add.
func (g *Gateway) beginRelay() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.stopping {
		return false
	}
	g.relays.Add(1)
	return true
}

func (g *Gateway) closeStreams() {
	g.mu.Lock()
	g.stopping = true
	all := make([]net.Conn, 0, len(g.connections))
	for c := range g.connections {
		all = append(all, c)
	}
	g.mu.Unlock()
	for _, c := range all {
		c.Close()
	}
}

func (g *Gateway) close() {
	g.cancel()
	g.closeStreams()
	g.listener.Close()
	g.server.Close() // Shutdown alone deliberately does not close hijacked streams.
	g.relays.Wait()
}

// All dialing is pinned to the reserved loopback core port. Request Host, absolute
// URLs and proxy headers never select a destination.
func dialTCP(ctx context.Context, addr *net.TCPAddr, timeout time.Duration) (*net.TCPConn, error) {
	d := net.Dialer{Timeout: timeout}
	conn, err := d.DialContext(ctx, "tcp4", addr.String())
	if err != nil {
		return nil, err
	}
	tcp, ok := conn.(*net.TCPConn)
	if !ok {
		conn.Close()
		return nil, errors.New("expected TCP connection")
	}
	tcp.SetNoDelay(true)
	return tcp, nil
}
