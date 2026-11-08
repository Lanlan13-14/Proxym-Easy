package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os/exec"
	"syscall"
	"time"
)

const (
	coreReadyTimeout = 15 * time.Second
	coreStopTimeout  = 5 * time.Second
)

type coreProcess struct {
	cmd  *exec.Cmd
	done chan struct{}
	err  error // written before done closes, read only after done
}

func reserveCorePort(excluded ...int) (*net.TCPListener, error) {
	for attempt := 0; attempt < 16; attempt++ {
		listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			return nil, errors.New("cannot reserve loopback core port")
		}
		port, conflict := listener.Addr().(*net.TCPAddr).Port, false
		for _, no := range excluded {
			conflict = conflict || port == no
		}
		if !conflict {
			return listener, nil
		}
		listener.Close()
	}
	return nil, errors.New("cannot reserve distinct loopback core port")
}

func coreArgs(c BootConfig, port int) []string {
	args := []string{"-c", c.ConfigPath, "--listeners", fmt.Sprintf("ws://127.0.0.1:%d", port),
		"--rpc-portal", fmt.Sprintf("127.0.0.1:%d", c.RPCPort),
		"--console-log-level", "warn", "--file-log-level", "off"}
	if c.NoTUN {
		args = append(args, "--no-tun")
	}
	return args
}

func launchCore(c BootConfig, reservation *net.TCPListener, stdout, stderr io.Writer) (*coreProcess, error) {
	port := reservation.Addr().(*net.TCPAddr).Port
	cmd := exec.Command(c.CorePath, coreArgs(c, port)...)
	cmd.Stdout, cmd.Stderr = stdout, stderr
	// No inherited descriptors, no shell, no boot JSON/secret in argv or env.
	// Release only immediately before Start: the core cannot adopt a Go listener.
	reservation.Close()
	if err := cmd.Start(); err != nil {
		return nil, errors.New("cannot start EasyTier core")
	}
	core := &coreProcess{cmd: cmd, done: make(chan struct{})}
	go func() {
		core.err = cmd.Wait() // exactly one waiter, always reap the owned child
		close(core.done)
	}()
	return core, nil
}

func (p *coreProcess) stop() {
	select {
	case <-p.done:
		return
	default:
	}
	_ = p.cmd.Process.Signal(syscall.SIGTERM)
	timer := time.NewTimer(coreStopTimeout)
	defer timer.Stop()
	select {
	case <-p.done:
		return
	case <-timer.C:
		_ = p.cmd.Process.Kill()
	}
	// Wait is already active; a second bounded interval avoids shutdown hanging
	// forever in an uninterruptible kernel state after SIGKILL.
	timer.Reset(coreStopTimeout)
	select {
	case <-p.done:
	case <-timer.C:
	}
}

func waitCoreReady(ctx context.Context, core *coreProcess, address *net.TCPAddr) error {
	readyCtx, cancel := context.WithTimeout(ctx, coreReadyTimeout)
	defer cancel()
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-core.done:
			return errors.New("EasyTier core exited before readiness")
		default:
		}
		conn, err := dialTCP(readyCtx, address, 200*time.Millisecond)
		if err == nil {
			conn.Close()
			select {
			case <-core.done:
				return errors.New("EasyTier core exited before readiness")
			default:
				return nil
			}
		}
		select {
		case <-readyCtx.Done():
			return errors.New("EasyTier core readiness timed out or cancelled")
		case <-core.done:
			return errors.New("EasyTier core exited before readiness")
		case <-tick.C:
		}
	}
}

func runGateway(ctx context.Context, c BootConfig, stdout, stderr io.Writer) error {
	if err := c.validate(); err != nil {
		return err
	}
	grant, err := newJoinGrant(c.Payload)
	if err != nil {
		return errors.New("cannot initialize invitation state")
	}
	reservation, err := reserveCorePort(c.ListenPort, c.RPCPort)
	if err != nil {
		return err
	}
	defer reservation.Close()
	address := reservation.Addr().(*net.TCPAddr)
	gateway, err := newGateway(c.ListenPort, address, c.Domain, grant)
	if err != nil {
		return err
	}
	defer gateway.close()
	core, err := launchCore(c, reservation, stdout, stderr)
	if err != nil {
		return err
	}
	defer func() {
		gateway.close()
		core.stop()
	}()
	if err := waitCoreReady(ctx, core, address); err != nil {
		if ctx.Err() != nil {
			return nil
		}
		return err
	}
	control, err := newControl(c.ControlPath, gateway)
	if err != nil {
		return err
	}
	defer control.close()
	failures := make(chan error, 2)
	go func() { failures <- gateway.server.Serve(gateway.listener) }()
	go func() { failures <- control.serve() }()
	gc := time.NewTicker(time.Second)
	defer gc.Stop()
	var result error
	listenerFailed := false
running:
	for {
		select {
		case <-ctx.Done():
			break running
		case <-core.done:
			result = errors.New("EasyTier core exited")
			break running
		case <-failures:
			listenerFailed = true
			result = errors.New("gateway listener stopped unexpectedly")
			break running
		case <-gc.C:
			grant.expire()
		}
	}
	gateway.close()
	control.close()
	// Both accept loops have been stopped; consume their results, never leak a
	// sender goroutine. An earlier error already consumed one of the two results.
	if !listenerFailed {
		<-failures
		<-failures
	} else {
		<-failures
	}
	return result
}
