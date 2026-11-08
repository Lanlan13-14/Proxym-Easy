//go:build !linux

package main

import "net"

// Production requires Linux SO_PEERCRED; fail closed on other platforms.
func rootPeer(conn *net.UnixConn) bool { return false }
