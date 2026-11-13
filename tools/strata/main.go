// Command strata is a terminal viewer for stratalog records streamed from a
// running Dart or Flutter app's VM service.
//
//	strata [--plain] [target]
//
// target defaults to ./.flutter.vmservice; see [vmservice.ResolveTarget].
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/esenmx/stratalog/tools/strata/internal/vmservice"
)

const defaultTarget = "./.flutter.vmservice"

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, os.Args[1:], os.Stdout)
	stop()
	if err != nil && !errors.Is(err, flag.ErrHelp) {
		fmt.Fprintln(os.Stderr, "strata:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("strata", flag.ContinueOnError)
	plain := fs.Bool("plain", false, "print one line per record to stdout instead of the TUI")
	fs.Usage = func() {
		_, _ = fmt.Fprintf(fs.Output(), "usage: strata [--plain] [target]\n\n"+
			"target: a VM service ws(s):// or http(s):// URI, or a file holding one\n"+
			"(default %s)\n\n", defaultTarget)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	target := defaultTarget
	switch fs.NArg() {
	case 0:
	case 1:
		target = fs.Arg(0)
	default:
		fs.Usage()
		return errors.New("at most one target")
	}
	if *plain {
		return runPlain(ctx, target, stdout)
	}
	return runTUI(ctx, target)
}

// runPlain prints each record's Plain line until ctx ends (nil) or the
// connection drops (error). It never reconnects.
func runPlain(ctx context.Context, target string, stdout io.Writer) error {
	wsURL, err := vmservice.ResolveTarget(target)
	if errors.Is(err, vmservice.ErrWaiting) {
		return fmt.Errorf("waiting for %s", target)
	}
	if err != nil {
		return err
	}
	c, err := vmservice.Dial(ctx, wsURL)
	if err != nil {
		return err
	}
	defer c.Close()

	var werr error
	err = vmservice.Stream(ctx, c, vmservice.NewDedup(), func(it vmservice.Item) {
		if werr == nil {
			_, werr = fmt.Fprintln(stdout, it.Rec.Plain())
		}
	})
	if n := c.Malformed(); n > 0 {
		fmt.Fprintf(os.Stderr, "strata: skipped %d malformed records\n", n)
	}
	switch {
	case werr != nil:
		return werr
	case ctx.Err() != nil:
		return nil
	default:
		return err
	}
}
