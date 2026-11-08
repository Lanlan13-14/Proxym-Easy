//go:build linux

package main

import (
	"net"
	"syscall"
)

// Root is checked on the accepted kernel peer, never a user-supplied JSON field.
func rootPeer(conn *net.UnixConn) bool {
	raw, err := conn.SyscallConn()
	if err != nil {
		return false
	}
	var cred *syscall.Ucred
	var sockErr error
	if err := raw.Control(func(fd uintptr) {
		cred, sockErr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	}); err != nil {
		return false
	}
	return sockErr == nil && cred != nil && cred.Uid == 0
}
