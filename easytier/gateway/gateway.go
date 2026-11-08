package main

import (
	"bufio"
	"context"
	"crypto/sha1"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

const (
	maxHTTPConnections = 64
	maxHeaderBytes     = 32 << 10
	handshakeTimeout   = 10 * time.Second
)

type Gateway struct {
	grant       *JoinGrant
	domain      string
	instanceID  string
	upstream    *net.TCPAddr
	listener    *gateListener
	server      *http.Server
	ctx         context.Context
	cancel      context.CancelFunc
	mu          sync.Mutex
	stopping    bool
	connections map[net.Conn]struct{}
	relays      sync.WaitGroup
}

func newGateway(port int, upstream *net.TCPAddr, domain string, grant *JoinGrant) (*Gateway, error) {
	if upstream == nil || !upstream.IP.Equal(net.IPv4(127, 0, 0, 1)) || upstream.Port < 1 || upstream.Port > 65535 {
		return nil, errors.New("core listener must be IPv4 loopback")
	}
	instance, err := randomHex(16)
	if err != nil {
		return nil, errors.New("cannot generate gateway instance")
	}
	ln, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port})
	if err != nil {
		return nil, errors.New("cannot bind gateway loopback listener")
	}
	ctx, cancel := context.WithCancel(context.Background())
	g := &Gateway{grant: grant, domain: domain, instanceID: instance, upstream: upstream,
		ctx: ctx, cancel: cancel, connections: make(map[net.Conn]struct{})}
	g.listener = &gateListener{TCPListener: ln, slots: make(chan struct{}, maxHTTPConnections), owner: g}
	g.server = &http.Server{Handler: g, ReadHeaderTimeout: handshakeTimeout, WriteTimeout: handshakeTimeout,
		IdleTimeout: handshakeTimeout, MaxHeaderBytes: maxHeaderBytes, ErrorLog: log.New(io.Discard, "", 0)}
	g.server.SetKeepAlivesEnabled(false)
	return g, nil
}

func (g *Gateway) port() int { return g.listener.Addr().(*net.TCPAddr).Port }

func reject(w http.ResponseWriter, status int) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Length", "0")
	w.Header().Set("Connection", "close")
	w.WriteHeader(status)
}

func writeJSON(w http.ResponseWriter, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", fmt.Sprint(len(body)))
	w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")
	w.Header().Set("Pragma", "no-cache")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Connection", "close")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func lowerHex(s string, size int) bool {
	if len(s) != size {
		return false
	}
	for _, ch := range s {
		if !(ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'f') {
			return false
		}
	}
	return true
}

func singleHeader(h http.Header, key, want string) bool {
	values := h.Values(key)
	return len(values) == 1 && strings.EqualFold(strings.TrimSpace(values[0]), want)
}

func headerToken(h http.Header, key, token string) bool {
	for _, line := range h.Values(key) {
		for _, item := range strings.Split(line, ",") {
			if strings.EqualFold(strings.TrimSpace(item), token) {
				return true
			}
		}
	}
	return false
}

func emptyRequest(r *http.Request) bool {
	return r.ContentLength == 0 && len(r.TransferEncoding) == 0 && len(r.Header.Values("Transfer-Encoding")) == 0 &&
		(r.Header.Get("Content-Length") == "" || singleHeader(r.Header, "Content-Length", "0")) &&
		r.Header.Get("Expect") == ""
}

func (g *Gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// RequestURI is checked too: no absolute-form proxy requests, escaped paths,
	// queries, or implicit redirects can ever become an invitation or a tunnel.
	if strings.HasPrefix(r.URL.Path, "/join/") {
		if r.Method == http.MethodGet || r.Method == http.MethodHead {
			reject(w, http.StatusMethodNotAllowed)
			return
		}
		if r.Method != http.MethodPost || r.RequestURI != r.URL.Path || !emptyRequest(r) ||
			!singleHeader(r.Header, "X-EasyTier-Join", "1") {
			reject(w, http.StatusNotFound)
			return
		}
		path := strings.TrimPrefix(r.URL.Path, "/join/")
		if strings.HasPrefix(path, "check/") && lowerHex(strings.TrimPrefix(path, "check/"), 32) {
			body, _ := json.Marshal(struct {
				Format     string `json:"format"`
				Nonce      string `json:"nonce"`
				InstanceID string `json:"instance_id"`
			}{"easytier-cf-gateway-v1", strings.TrimPrefix(path, "check/"), g.instanceID})
			writeJSON(w, body)
			return
		}
		if lowerHex(path, 64) {
			if body := g.grant.claim(path); body != nil {
				writeJSON(w, body)
				return
			}
		}
		reject(w, http.StatusNotFound)
		return
	}
	if r.Method != http.MethodGet || r.RequestURI != "/" || r.ProtoMajor != 1 || r.ProtoMinor != 1 || !emptyRequest(r) ||
		!singleHeader(r.Header, "Upgrade", "websocket") || !headerToken(r.Header, "Connection", "upgrade") ||
		!singleHeader(r.Header, "Sec-WebSocket-Version", "13") {
		reject(w, http.StatusNotFound)
		return
	}
	key := r.Header.Get("Sec-WebSocket-Key")
	decoded, err := base64.StdEncoding.Strict().DecodeString(key)
	if err != nil || len(decoded) != 16 || len(r.Header.Values("Sec-WebSocket-Key")) != 1 {
		reject(w, http.StatusNotFound)
		return
	}
	g.websocket(w, r, key)
}

// limitedHeaderReader bounds an untrusted core response even though ReadResponse
// itself has no header-size option. It is never used in the post-101 data plane.
type limitedHeaderReader struct {
	r io.Reader
	n int
}

func (r *limitedHeaderReader) Read(p []byte) (int, error) {
	if r.n <= 0 {
		return 0, errors.New("core handshake header too large")
	}
	if len(p) > r.n {
		p = p[:r.n]
	}
	n, err := r.r.Read(p)
	r.n -= n
	return n, err
}

func websocketAccept(key string) string {
	sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	return base64.StdEncoding.EncodeToString(sum[:])
}

func (g *Gateway) websocket(w http.ResponseWriter, r *http.Request, key string) {
	upstream, err := dialTCP(g.ctx, g.upstream, handshakeTimeout)
	if err != nil {
		reject(w, http.StatusBadGateway)
		return
	}
	defer upstream.Close()
	if !g.track(upstream) {
		reject(w, http.StatusServiceUnavailable)
		return
	}
	defer g.untrack(upstream)
	upstream.SetDeadline(time.Now().Add(handshakeTimeout))
	// Manual serialization keeps the original request target, Host and all
	// WebSocket extension/subprotocol headers, without ReverseProxy rewriting.
	var request strings.Builder
	fmt.Fprintf(&request, "%s %s %s\r\nHost: %s\r\n", r.Method, r.RequestURI, r.Proto, r.Host)
	if err := r.Header.Write(&request); err != nil || request.Len()+2 > maxHeaderBytes {
		reject(w, http.StatusRequestHeaderFieldsTooLarge)
		return
	}
	request.WriteString("\r\n")
	if _, err := io.WriteString(upstream, request.String()); err != nil {
		reject(w, http.StatusBadGateway)
		return
	}
	reader := bufio.NewReaderSize(&limitedHeaderReader{r: upstream, n: maxHeaderBytes}, 4096)
	response, err := http.ReadResponse(reader, r)
	if err != nil {
		reject(w, http.StatusBadGateway)
		return
	}
	// Never forward a core error page, redirect, or unverified upgrade response.
	accept := response.Header.Get("Sec-WebSocket-Accept")
	if response.StatusCode != http.StatusSwitchingProtocols || response.ProtoMajor != 1 || response.ProtoMinor != 1 ||
		!singleHeader(response.Header, "Upgrade", "websocket") || !headerToken(response.Header, "Connection", "upgrade") ||
		len(response.Header.Values("Sec-WebSocket-Accept")) != 1 ||
		subtle.ConstantTimeCompare([]byte(accept), []byte(websocketAccept(key))) != 1 ||
		len(response.TransferEncoding) != 0 || response.ContentLength > 0 {
		reject(w, http.StatusBadGateway)
		return
	}
	hijacker, ok := w.(http.Hijacker)
	if !ok || !g.beginRelay() {
		reject(w, http.StatusServiceUnavailable)
		return
	}
	defer g.relays.Done()
	conn, rw, err := hijacker.Hijack()
	if err != nil {
		return
	}
	defer conn.Close()
	client, ok := rawTCP(conn)
	if !ok {
		return
	}
	client.SetNoDelay(true)
	deadline := time.Now().Add(handshakeTimeout)
	client.SetDeadline(deadline)
	fmt.Fprintf(rw.Writer, "%s %s\r\n", response.Proto, response.Status)
	if err := response.Header.Write(rw.Writer); err != nil {
		return
	}
	if _, err := rw.Writer.WriteString("\r\n"); err != nil {
		return
	}
	if err := rw.Writer.Flush(); err != nil {
		return
	}
	client.SetDeadline(time.Time{})
	upstream.SetDeadline(time.Time{})
	relayTCP(client, upstream, rw.Reader, reader)
}

// relayTCP drains only bytes prefetched during the two handshakes, then passes
// TWO REAL *net.TCPConn VALUES to io.Copy. On Linux this selects net's splice
// fast path. Never pass a gateConn, bufio.Reader, TeeReader, or CopyBuffer here.
// Each clean EOF half-closes just the opposite write side; both directions must
// finish, so a final server response after client CloseWrite is not truncated.
func relayTCP(client, upstream *net.TCPConn, clientBuffered, upstreamBuffered *bufio.Reader) {
	done := make(chan struct{}, 2)
	copyOne := func(dst, src *net.TCPConn, buffered *bufio.Reader) {
		defer func() { done <- struct{}{} }()
		var err error
		if n := buffered.Buffered(); n != 0 {
			_, err = io.CopyN(dst, buffered, int64(n))
		}
		if err == nil {
			_, err = io.Copy(dst, src)
		}
		if err != nil {
			// A hard reset/write failure cannot sustain a useful half-open stream.
			client.Close()
			upstream.Close()
			return
		}
		dst.CloseWrite()
	}
	go copyOne(upstream, client, clientBuffered)
	go copyOne(client, upstream, upstreamBuffered)
	<-done
	<-done
}
