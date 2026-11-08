package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
)

func gatewayMain(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("easytier-gateway", flag.ContinueOnError)
	// flag errors can include argv: emit only our fixed, non-secret diagnostic.
	flags.SetOutput(io.Discard)
	showVersion := flags.Bool("version", false, "print version")
	fd := flags.Int("config-fd", -1, "inherited boot configuration descriptor")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		fmt.Fprintln(stderr, "invalid easytier-gateway arguments")
		return 2
	}
	if *showVersion {
		fmt.Fprintln(stdout, "easytier-gateway "+version)
		return 0
	}
	if os.Geteuid() != 0 {
		fmt.Fprintln(stderr, "easytier-gateway must run as root")
		return 1
	}
	config, err := readBoot(*fd)
	if err != nil {
		fmt.Fprintln(stderr, err.Error())
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := runGateway(ctx, config, stdout, stderr); err != nil {
		fmt.Fprintln(stderr, err.Error())
		return 1
	}
	return 0
}

func main() { os.Exit(gatewayMain(os.Args[1:], os.Stdout, os.Stderr)) }
