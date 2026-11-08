package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestGrantOnceRotationRevocationExpiry(t *testing.T) {
	g, err := newJoinGrant(testPayload())
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	g.now = func() time.Time { return now }
	first, err := g.issue()
	if err != nil || !lowerHex(first, 64) || g.status(first) != "active" {
		t.Fatal("issue failed")
	}
	var claimed atomic.Int32
	var workers sync.WaitGroup
	for i := 0; i < 80; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			if body := g.claim(first); body != nil {
				claimed.Add(1)
			}
		}()
	}
	workers.Wait()
	if claimed.Load() != 1 || g.status(first) != "consumed" || g.claim(first) != nil {
		t.Fatal("invitation was not consumed exactly once")
	}
	second, _ := g.issue()
	if g.status(first) != "superseded" || g.claim(first) != nil || g.status(second) != "active" {
		t.Fatal("rotation retained old invitation")
	}
	if g.revoke(first) != "superseded" || g.status(second) != "active" {
		t.Fatal("old revoke affected current invitation")
	}
	if g.revoke(second) != "revoked" || g.claim(second) != nil || g.revoke(second) != "revoked" {
		t.Fatal("revocation failed")
	}
	third, _ := g.issue()
	now = now.Add(joinTTL - time.Nanosecond)
	if g.status(third) != "active" {
		t.Fatal("expired early")
	}
	now = now.Add(time.Nanosecond)
	g.expire()
	if g.status(third) != "expired" || g.body != nil || g.claim(third) != nil {
		t.Fatal("expiry boundary/cleanup failed")
	}
	if g.status(strings.Repeat("a", 64)) != "superseded" {
		t.Fatal("unknown token should have no persistent history")
	}
}

func TestJoinGETHEADAndProof(t *testing.T) {
	g := fixtureGateway(t, nil)
	token := issueToken(t, g)
	for _, method := range []string{http.MethodGet, http.MethodHead} {
		for _, path := range []string{"/join/" + token, "/join/check/" + strings.Repeat("a", 32), "/join/unknown"} {
			status, body, headers := gatewayRequest(t, g, method, path, true)
			if status != 405 || len(body) != 0 || headers.Get("Content-Length") != "0" || headers.Get("Cache-Control") != "no-store" {
				t.Fatalf("%s %s: %d body=%d", method, path, status, len(body))
			}
		}
	}
	if g.grant.status(token) != "active" {
		t.Fatal("safe methods consumed invitation")
	}
	for _, state := range []string{"active", "consumed", "revoked", "expired"} {
		g.grant.mu.Lock()
		g.grant.result = state
		g.grant.mu.Unlock()
		nonce := strings.Repeat("a", 32)
		status, body, headers := gatewayRequest(t, g, "POST", "/join/check/"+nonce, true)
		var proof map[string]string
		if status != 200 || json.Unmarshal(body, &proof) != nil || len(proof) != 3 ||
			proof["format"] != "easytier-cf-gateway-v1" || proof["nonce"] != nonce || proof["instance_id"] != g.instanceID ||
			!lowerHex(proof["instance_id"], 32) || !strings.Contains(headers.Get("Cache-Control"), "no-store") ||
			bytes.Contains(body, []byte(token)) || bytes.Contains(body, []byte(testPayload().Secret)) {
			t.Fatalf("proof mismatch for invitation state %s", state)
		}
	}
}

func TestHTTPAtomicClaimAndPayload(t *testing.T) {
	g := fixtureGateway(t, nil)
	token := issueToken(t, g)
	var wins atomic.Int32
	var workers sync.WaitGroup
	for i := 0; i < 32; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			status, body, headers := gatewayRequest(t, g, "POST", "/join/"+token, true)
			if status == 200 {
				wins.Add(1)
				var payload JoinPayload
				var keys map[string]any
				if json.Unmarshal(body, &payload) != nil || payload != testPayload() || json.Unmarshal(body, &keys) != nil || len(keys) != 6 ||
					!strings.Contains(headers.Get("Cache-Control"), "no-store") || headers.Get("X-Content-Type-Options") != "nosniff" {
					t.Error("client payload fields/cache policy changed")
				}
			} else if status != 404 || len(body) != 0 {
				t.Errorf("unexpected claim status=%d body=%d", status, len(body))
			}
		}()
	}
	workers.Wait()
	if wins.Load() != 1 || g.grant.status(token) != "consumed" {
		t.Fatalf("successful claims=%d", wins.Load())
	}
}

func TestJoinInvalidPathsDoNotConsume(t *testing.T) {
	g := fixtureGateway(t, nil)
	token := issueToken(t, g)
	for _, path := range []string{"/join/" + token + "?x=1", "/join/" + strings.ToUpper(token), "/join/" + token + "/",
		"/join/" + token[:63], "/join/check/" + strings.Repeat("a", 31), "/join/check/" + strings.Repeat("A", 32)} {
		status, body, _ := gatewayRequest(t, g, "POST", path, true)
		if status != 404 || len(body) != 0 {
			t.Fatalf("invalid join returned %d body=%d", status, len(body))
		}
	}
	status, body, _ := gatewayRequest(t, g, "POST", "/join/"+token, false)
	if status != 404 || len(body) != 0 || g.grant.status(token) != "active" {
		t.Fatal("unmarked request consumed invitation")
	}
	status, body, _ = gatewayRequest(t, g, "POST", "/join/"+token, true)
	if status != 200 || len(body) == 0 {
		t.Fatal("valid POST failed after invalid requests")
	}
}
