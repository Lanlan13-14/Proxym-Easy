package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const (
	version        = "1.0.0"
	gatewayVersion = 3
	maxBootBytes   = 64 << 10
)

// JoinPayload deliberately retains the existing six-field client format.
// It is never written to disk, passed in argv, or included in diagnostic errors.
type JoinPayload struct {
	Format     string `json:"format"`
	Domain     string `json:"domain"`
	Network    string `json:"network"`
	Secret     string `json:"secret"`
	Subnet     string `json:"subnet"`
	ServerName string `json:"server_name"`
}

type BootConfig struct {
	ListenPort  int         `json:"listen_port"`
	ControlPath string      `json:"control_path"`
	Domain      string      `json:"domain"`
	Payload     JoinPayload `json:"payload"`
	CorePath    string      `json:"core_path"`
	ConfigPath  string      `json:"config_path"`
	RPCPort     int         `json:"rpc_port"`
	NoTUN       bool        `json:"no_tun,omitempty"`
}

var (
	namePattern   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$`)
	domainPattern = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)
)

func validDomain(domain string) bool {
	if len(domain) > 253 || !strings.Contains(domain, ".") {
		return false
	}
	for _, label := range strings.Split(domain, ".") {
		if !domainPattern.MatchString(label) {
			return false
		}
	}
	return true
}

func (c BootConfig) validate() error {
	bad := errors.New("invalid gateway boot configuration")
	if c.ListenPort < 1 || c.ListenPort > 65535 || c.RPCPort < 1 || c.RPCPort > 65535 || c.ListenPort == c.RPCPort {
		return bad
	}
	for _, path := range []string{c.ControlPath, c.CorePath, c.ConfigPath} {
		if !filepath.IsAbs(path) || filepath.Clean(path) != path || strings.ContainsRune(path, 0) {
			return bad
		}
	}
	p := c.Payload
	if !validDomain(c.Domain) || p.Domain != c.Domain || p.Format != "easytier-cf-join-v1" ||
		!namePattern.MatchString(p.Network) || !namePattern.MatchString(p.ServerName) || len(p.Secret) < 40 || len(p.Secret) > 256 {
		return bad
	}
	for _, ch := range p.Secret {
		if ch < 33 || ch > 126 {
			return bad
		}
	}
	subnet, err := netip.ParsePrefix(p.Subnet)
	if err != nil || !subnet.Addr().Is4() || subnet.Bits() != 24 || subnet != subnet.Masked() || !subnet.Addr().IsPrivate() {
		return bad
	}
	return nil
}

// readBoot always closes the inherited descriptor, including on malformed or
// oversized input. Reading one extra byte distinguishes an exact-limit document.
func readBoot(fd int) (BootConfig, error) {
	var c BootConfig
	if fd < 3 {
		return c, errors.New("configuration must use an inherited descriptor >= 3")
	}
	file := os.NewFile(uintptr(fd), "gateway-boot")
	if file == nil {
		return c, errors.New("cannot read gateway boot configuration")
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, maxBootBytes+1))
	if err != nil || len(raw) > maxBootBytes {
		return c, errors.New("cannot read bounded gateway boot configuration")
	}
	defer clear(raw)
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&c) != nil {
		return BootConfig{}, errors.New("invalid gateway boot JSON")
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return BootConfig{}, errors.New("gateway boot JSON must contain one object")
	}
	if err := c.validate(); err != nil {
		return BootConfig{}, err
	}
	return c, nil
}
