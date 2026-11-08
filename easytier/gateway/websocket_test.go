package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const testWSKey = "AAECAwQFBgcICQoLDA0ODw=="

func wsRequest() string {
	return "GET / HTTP/1.1\r\nHost: original.example.test\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n" +
		"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + testWSKey + "\r\n" +
		"Origin: https://original.example.test\r\nSec-WebSocket-Protocol: binary\r\nSec-WebSocket-Extensions: example-extension\r\nX-Original: retain-me\r\n\r\n"
}

func wsResponse() string {
	return "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " +
		websocketAccept(testWSKey) + "\r\nSec-WebSocket-Protocol: binary\r\n\r\n"
}

func fakeWSCore(t *testing.T, handler func(*net.TCPConn, *http.Request, *bufio.Reader)) (*net.TCPAddr, *atomic.Int32) {
	t.Helper()
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	var accepted atomic.Int32
	var workers sync.WaitGroup
	var mu sync.Mutex
	connections := make(map[*net.TCPConn]bool)
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		for {
			conn, err := listener.AcceptTCP()
			if err != nil {
				return
			}
			accepted.Add(1)
			mu.Lock()
			connections[conn] = true
			mu.Unlock()
			workers.Add(1)
			go func() {
				defer workers.Done()
				defer func() { conn.Close(); mu.Lock(); delete(connections, conn); mu.Unlock() }()
				conn.SetDeadline(time.Now().Add(5 * time.Second))
				reader := bufio.NewReader(conn)
				req, err := http.ReadRequest(reader)
				if err != nil {
					return
				}
				handler(conn, req, reader)
			}()
		}
	}()
	t.Cleanup(func() {
		listener.Close()
		<-stopped
		mu.Lock()
		for c := range connections {
			c.Close()
		}
		mu.Unlock()
		workers.Wait()
	})
	return listener.Addr().(*net.TCPAddr), &accepted
}

func rawHTTP(t *testing.T, g *Gateway, request string) (*http.Response, []byte) {
	t.Helper()
	conn, err := net.DialTimeout("tcp4", g.listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.WriteString(conn, request); err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	return response, body
}

func wsFrame(payload []byte, masked bool) []byte {
	var b bytes.Buffer
	b.WriteByte(0x82) // FIN binary, no UTF-8 assumptions
	flag := byte(0)
	if masked {
		flag = 0x80
	}
	if len(payload) < 126 {
		b.WriteByte(flag | byte(len(payload)))
	} else {
		b.WriteByte(flag | 126)
		_ = binary.Write(&b, binary.BigEndian, uint16(len(payload)))
	}
	mask := [4]byte{0x17, 0xa1, 0x00, 0xff}
	if masked {
		b.Write(mask[:])
	}
	for i, ch := range payload {
		if masked {
			ch ^= mask[i%4]
		}
		b.WriteByte(ch)
	}
	return b.Bytes()
}

func readWSFrame(r io.Reader, masked bool) ([]byte, error) {
	var header [2]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}
	if header[0] != 0x82 || (header[1]&0x80 != 0) != masked {
		return nil, fmt.Errorf("binary frame/mask not preserved")
	}
	size := int(header[1] & 0x7f)
	if size == 126 {
		var length uint16
		if err := binary.Read(r, binary.BigEndian, &length); err != nil {
			return nil, err
		}
		size = int(length)
	} else if size == 127 {
		return nil, fmt.Errorf("unexpected oversized frame")
	}
	var mask [4]byte
	if masked {
		if _, err := io.ReadFull(r, mask[:]); err != nil {
			return nil, err
		}
	}
	payload := make([]byte, size)
	if _, err := io.ReadFull(r, payload); err != nil {
		return nil, err
	}
	if masked {
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
	}
	return payload, nil
}

func TestWebSocketBinaryPipelineAndHalfClose(t *testing.T) {
	payloads := [][]byte{{0x00, 0xff, 0x80, 0x01}, bytes.Repeat([]byte{0x00, 0xff, 0xac, 0x7f}, 1024)}
	greeting, goodbye := []byte("pipelined-server-frame"), []byte("reply-after-client-EOF")
	addr, accepted := fakeWSCore(t, func(conn *net.TCPConn, request *http.Request, r *bufio.Reader) {
		if request.RequestURI != "/" || request.Host != "original.example.test" || request.Header.Get("X-Original") != "retain-me" ||
			request.Header.Get("Origin") != "https://original.example.test" || request.Header.Get("Sec-WebSocket-Extensions") != "example-extension" ||
			request.Header.Get("Connection") != "keep-alive, Upgrade" {
			t.Error("original handshake headers changed")
		}
		// Same write: core's response reader can prefetch a binary frame.
		packet := append([]byte(wsResponse()), wsFrame(greeting, false)...)
		if _, err := conn.Write(packet); err != nil {
			t.Error(err)
			return
		}
		for _, want := range payloads {
			got, err := readWSFrame(r, true)
			if err != nil || !bytes.Equal(got, want) {
				t.Error("masked/pipelined client frame was corrupted", err)
				return
			}
			if _, err := conn.Write(wsFrame(got, false)); err != nil {
				t.Error(err)
				return
			}
		}
		if remaining, err := io.ReadAll(r); err != nil || len(remaining) != 0 {
			t.Error("client half-close did not propagate", err)
			return
		}
		conn.Write(wsFrame(goodbye, false))
		conn.CloseWrite()
	})
	g := fixtureGateway(t, addr)
	conn, err := net.DialTCP("tcp4", nil, g.listener.Addr().(*net.TCPAddr))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	packet := []byte(wsRequest())
	for _, payload := range payloads {
		packet = append(packet, wsFrame(payload, true)...)
	}
	if _, err := conn.Write(packet); err != nil {
		t.Fatal(err)
	}
	r := bufio.NewReader(conn)
	response, err := http.ReadResponse(r, nil)
	if err != nil || response.StatusCode != 101 || response.Header.Get("Sec-WebSocket-Protocol") != "binary" {
		t.Fatal("upgrade failed", err)
	}
	for _, want := range append([][]byte{greeting}, payloads...) {
		got, err := readWSFrame(r, false)
		if err != nil || !bytes.Equal(got, want) {
			t.Fatal("server binary bytes corrupted", err)
		}
	}
	conn.CloseWrite()
	got, err := readWSFrame(r, false)
	if err != nil || !bytes.Equal(got, goodbye) {
		t.Fatal("final response after half-close lost", err)
	}
	if _, err := r.ReadByte(); err != io.EOF {
		t.Fatal("server EOF did not propagate", err)
	}
	if accepted.Load() != 1 {
		t.Fatal("gateway opened unexpected TCP connections")
	}
}

func TestWebSocketInvalidClientNeverDials(t *testing.T) {
	addr, accepted := fakeWSCore(t, func(conn *net.TCPConn, _ *http.Request, _ *bufio.Reader) { t.Error("invalid client reached core") })
	g := fixtureGateway(t, addr)
	base := wsRequest()
	for _, item := range []struct{ name, request string }{
		{"bad_connection_token", strings.Replace(base, "keep-alive, Upgrade", "notupgrade", 1)},
		{"wrong_upgrade", strings.Replace(base, "Upgrade: websocket", "Upgrade: h2c", 1)},
		{"duplicate_upgrade", strings.Replace(base, "Upgrade: websocket", "Upgrade: websocket\r\nUpgrade: websocket", 1)},
		{"invalid_key", strings.Replace(base, testWSKey, "not-base64", 1)},
		{"short_key", strings.Replace(base, testWSKey, "AAAA", 1)},
		{"duplicate_key", strings.Replace(base, "Sec-WebSocket-Key: "+testWSKey, "Sec-WebSocket-Key: "+testWSKey+"\r\nSec-WebSocket-Key: "+testWSKey, 1)},
		{"version", strings.Replace(base, "Version: 13", "Version: 12", 1)},
		{"absolute_proxy", strings.Replace(base, "GET / HTTP", "GET http://127.0.0.1:9/ HTTP", 1)},
		{"query", strings.Replace(base, "GET / HTTP", "GET /?upstream=evil HTTP", 1)},
		{"path", strings.Replace(base, "GET / HTTP", "GET /other HTTP", 1)},
		{"connect", "CONNECT 127.0.0.1:9 HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n"},
		{"body", strings.Replace(base, "\r\n\r\n", "\r\nContent-Length: 1\r\n\r\nx", 1)},
		{"chunked", strings.Replace(base, "\r\n\r\n", "\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", 1)},
	} {
		t.Run(item.name, func(t *testing.T) {
			response, body := rawHTTP(t, g, item.request)
			if response.StatusCode != 404 || len(body) != 0 {
				t.Fatalf("status=%d body=%d", response.StatusCode, len(body))
			}
		})
	}
	if accepted.Load() != 0 {
		t.Fatal("gateway is an open TCP proxy")
	}
}

func TestWebSocketInvalidUpstream(t *testing.T) {
	for _, item := range []struct{ name, reply string }{
		{"invalid_accept", strings.Replace(wsResponse(), websocketAccept(testWSKey), "invalid", 1)},
		{"wrong_upgrade", strings.Replace(wsResponse(), "Upgrade: websocket", "Upgrade: other", 1)},
		{"connection_substring", strings.Replace(wsResponse(), "Connection: Upgrade", "Connection: notupgrade", 1)},
		{"duplicate_accept", strings.Replace(wsResponse(), "Sec-WebSocket-Accept: ", "Sec-WebSocket-Accept: bad\r\nSec-WebSocket-Accept: ", 1)},
		{"redirect", "HTTP/1.1 302 Found\r\nLocation: https://evil.invalid/\r\nContent-Length: 0\r\n\r\n"},
		{"giant_header", "HTTP/1.1 101 Switching Protocols\r\nX-Large: " + strings.Repeat("x", maxHeaderBytes+1) + "\r\n\r\n"},
		{"truncated", "HTTP/1.1 101 Switching"},
	} {
		t.Run(item.name, func(t *testing.T) {
			addr, _ := fakeWSCore(t, func(conn *net.TCPConn, _ *http.Request, _ *bufio.Reader) { io.WriteString(conn, item.reply) })
			g := fixtureGateway(t, addr)
			response, body := rawHTTP(t, g, wsRequest())
			if response.StatusCode != 502 || len(body) != 0 || response.Header.Get("Location") != "" {
				t.Fatal("invalid upstream upgrade was forwarded")
			}
		})
	}
}

func TestJoinBodiesAndTransferEncoding(t *testing.T) {
	g := fixtureGateway(t, nil)
	token := issueToken(t, g)
	for _, suffix := range []string{
		"Content-Length: 1\r\n\r\nx",
		"Content-Length: 00\r\n\r\n",
		"Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
		"Expect: 100-continue\r\nContent-Length: 0\r\n\r\n",
		"X-EasyTier-Join: 1\r\nContent-Length: 0\r\n\r\n", // duplicate join marker
	} {
		response, body := rawHTTP(t, g, "POST /join/"+token+" HTTP/1.1\r\nHost: test\r\nX-EasyTier-Join: 1\r\n"+suffix)
		if response.StatusCode != 404 || len(body) != 0 || g.grant.status(token) != "active" {
			t.Fatal("body/ambiguous headers consumed invitation")
		}
	}
}

func TestWebSocketShutdownClosesFullStream(t *testing.T) {
	addr, _ := fakeWSCore(t, func(conn *net.TCPConn, _ *http.Request, r *bufio.Reader) {
		io.WriteString(conn, wsResponse())
		io.Copy(io.Discard, r)
	})
	g := fixtureGateway(t, addr)
	conn, err := net.DialTimeout("tcp4", g.listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	io.WriteString(conn, wsRequest())
	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, nil)
	if err != nil || response.StatusCode != 101 {
		t.Fatal("upgrade failed", err)
	}
	done := make(chan struct{})
	go func() { g.close(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("shutdown blocked on hijacked stream")
	}
	if _, err := reader.ReadByte(); err == nil {
		t.Fatal("stream survived shutdown")
	}
}

func TestGatewayLoopbackOnlyAndAdmissionLimit(t *testing.T) {
	g := fixtureGateway(t, nil)
	if !g.listener.Addr().(*net.TCPAddr).IP.Equal(net.IPv4(127, 0, 0, 1)) || g.server.ReadHeaderTimeout != 10*time.Second {
		t.Fatal("listener/slowloris contract changed")
	}
	var clients []net.Conn
	defer func() {
		for _, conn := range clients {
			conn.Close()
		}
	}()
	for i := 0; i < maxHTTPConnections; i++ {
		conn, err := net.DialTimeout("tcp4", g.listener.Addr().String(), time.Second)
		if err != nil {
			t.Fatal(err)
		}
		io.WriteString(conn, "GET /")
		clients = append(clients, conn)
	}
	waitFor(t, func() bool { return len(g.listener.slots) == maxHTTPConnections })
	extra, err := net.DialTimeout("tcp4", g.listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer extra.Close()
	extra.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := extra.Read(make([]byte, 1)); err == nil {
		t.Fatal("excess HTTP connection was not rejected")
	} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("excess HTTP connection was left waiting")
	}
	clients[0].Close()
	waitFor(t, func() bool { return len(g.listener.slots) == maxHTTPConnections-1 })
	if upstream, err := newGateway(0, &net.TCPAddr{IP: net.ParseIP("192.0.2.1"), Port: 1234}, "example.com", g.grant); err == nil {
		upstream.close()
		t.Fatal("non-loopback core address accepted")
	}
}
