package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"sync"
	"time"
)

const joinTTL = 15 * time.Minute

// JoinGrant keeps only the current invitation. Old tokens have no history table:
// any non-current token is superseded. now uses Go's monotonic time in production.
type JoinGrant struct {
	mu       sync.Mutex
	token    string
	payload  []byte // immutable boot payload, needed for subsequent issues
	body     []byte // non-nil only while the current invitation is active
	deadline time.Time
	result   string
	now      func() time.Time
}

func randomHex(size int) (string, error) {
	b := make([]byte, size)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func newJoinGrant(payload JoinPayload) (*JoinGrant, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	return &JoinGrant{payload: body, result: "superseded", now: time.Now}, nil
}

func (g *JoinGrant) issue() (string, error) {
	token, err := randomHex(32)
	if err != nil {
		return "", err
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.token, g.body = token, g.payload
	g.deadline, g.result = g.now().Add(joinTTL), "active"
	return token, nil
}

func (g *JoinGrant) expireLocked() {
	if g.result == "active" && !g.now().Before(g.deadline) {
		g.body, g.result = nil, "expired"
	}
}

func (g *JoinGrant) statusLocked(token string) string {
	g.expireLocked()
	if g.token == "" || subtle.ConstantTimeCompare([]byte(token), []byte(g.token)) != 1 {
		return "superseded"
	}
	return g.result
}

func (g *JoinGrant) status(token string) string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.statusLocked(token)
}

func (g *JoinGrant) revoke(token string) string {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.statusLocked(token) == "active" {
		g.body, g.result = nil, "revoked"
	}
	return g.statusLocked(token)
}

func (g *JoinGrant) claim(token string) []byte {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.statusLocked(token) != "active" {
		return nil
	}
	body := g.body
	g.body, g.result = nil, "consumed"
	return body
}

func (g *JoinGrant) expire() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.expireLocked()
}
