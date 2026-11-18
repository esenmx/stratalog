// Command strata inspects and streams stratalog records from a running Dart or
// Flutter VM service, or replays saved NDJSON captures.
//
//	strata [flags] [target]
//
// target defaults to ./.flutter.vmservice (falling back to STRATA_TARGET or
// VM_SERVICE_URI); see [vmservice.Resolve].
package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/charmbracelet/x/term"

	"github.com/esenmx/stratalog/tools/strata/record"
	"github.com/esenmx/stratalog/tools/strata/termsafe"
	"github.com/esenmx/stratalog/tools/strata/vmservice"
)

const (
	defaultTarget = "./.flutter.vmservice"
	dialTimeout   = 5 * time.Second
)

type outputMode int

const (
	modeTUI outputMode = iota
	modePlain
	modeJSON
)

type cliConfig struct {
	target   string
	explicit bool
	mode     outputMode
	once     bool
	wait     bool
	levelIdx int
	layers   map[string]bool
	query    string
	filter   record.Filter
}

type runEnv struct {
	stdin  io.Reader
	stdout io.Writer
	stderr io.Writer
	isTTY  bool
	poll   time.Duration
	// historyGrace bounds how long --wait --once polls for an isolate to
	// register the history extension; zero means [vmservice.HistoryTimeout].
	historyGrace time.Duration
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	env := runEnv{
		stdin:  os.Stdin,
		stdout: os.Stdout,
		stderr: os.Stderr,
		isTTY:  term.IsTerminal(os.Stdout.Fd()),
		poll:   pollInterval,
	}
	err := env.run(ctx, os.Args[1:])
	stop()
	if err != nil && !errors.Is(err, flag.ErrHelp) {
		reportError(os.Stderr, err)
		os.Exit(1)
	}
}

// reportError writes err one "strata:"-prefixed line per line of its text,
// escaped: errors carry VM-supplied text (isolate names, RPC messages) that
// must not drive the terminal.
func reportError(w io.Writer, err error) {
	for line := range strings.SplitSeq(err.Error(), "\n") {
		_, _ = fmt.Fprintln(w, "strata:", termsafe.Line(line))
	}
}

func (e runEnv) pollEvery() time.Duration {
	if e.poll > 0 {
		return e.poll
	}
	return pollInterval
}

func (e runEnv) historyGraceOrDefault() time.Duration {
	if e.historyGrace > 0 {
		return e.historyGrace
	}
	return vmservice.HistoryTimeout
}

func (e runEnv) errOut() io.Writer {
	if e.stderr != nil {
		return e.stderr
	}
	return io.Discard
}

func (e runEnv) inReader() io.Reader {
	if e.stdin != nil {
		return e.stdin
	}
	return bytes.NewReader(nil)
}

func (e runEnv) run(ctx context.Context, args []string) error {
	cfg, err := parseCLI(args, e.isTTY, e.errOut())
	if err != nil {
		return err
	}
	if cfg.mode == modeTUI {
		return e.runTUI(ctx, cfg)
	}
	return e.runCLI(ctx, cfg)
}

func parseCLI(args []string, isTTY bool, usageOut io.Writer) (cliConfig, error) {
	fs := flag.NewFlagSet("strata", flag.ContinueOnError)
	fs.SetOutput(usageOut)

	plain := fs.Bool("plain", false, "print one ANSI-free line per record to stdout")
	jsonOut := fs.Bool("json", false, "print one lossless record_v1 NDJSON line per record")
	once := fs.Bool("once", false, "snapshot buffered history (or replay file) and exit")
	wait := fs.Bool("wait", false, "wait for target to appear in CLI modes")

	var levelName, layerCSV, grepQuery string
	fs.StringVar(&levelName, "level", "", "minimum chirp level (trace..wtf)")
	fs.StringVar(&levelName, "l", "", "shorthand for -level")
	fs.StringVar(&layerCSV, "layer", "", "comma-separated layer names (case-insensitive)")
	fs.StringVar(&layerCSV, "L", "", "shorthand for -layer")
	fs.StringVar(&grepQuery, "grep", "", "case-insensitive substring filter")
	fs.StringVar(&grepQuery, "g", "", "shorthand for -grep")

	fs.Usage = func() {
		_, _ = fmt.Fprintf(fs.Output(), "usage: strata [flags] [target]\n\n"+
			"target:\n"+
			"  ws(s):// or http(s):// VM service URI\n"+
			"  file holding a URI, --write-service-info JSON, or flutter/dart run log\n"+
			"  .jsonl/.ndjson capture file, or - for stdin\n"+
			"  (default %s, or $STRATA_TARGET / $VM_SERVICE_URI)\n\nflags:\n", defaultTarget)
		fs.PrintDefaults()
	}

	if err := fs.Parse(permuteArgs(fs, args)); err != nil {
		return cliConfig{}, err
	}
	if *plain && *jsonOut {
		return cliConfig{}, errors.New("cannot combine --plain and --json")
	}

	target := defaultTarget
	explicit := false
	switch fs.NArg() {
	case 0:
	case 1:
		target = fs.Arg(0)
		explicit = true
	default:
		fs.Usage()
		return cliConfig{}, errors.New("at most one target")
	}

	levelIdx := 0
	if strings.TrimSpace(levelName) != "" {
		var ok bool
		levelIdx, ok = record.ParseLevel(levelName)
		if !ok {
			return cliConfig{}, fmt.Errorf("unknown level %q (want trace, debug, info, notice, success, warning, error, critical, or wtf)", levelName)
		}
	}
	layers := parseLayerSet(layerCSV)
	q := strings.ToLower(strings.TrimSpace(grepQuery))

	mode := modeTUI
	switch {
	case *jsonOut:
		mode = modeJSON
	case *plain || *once || !isTTY:
		mode = modePlain
	}

	return cliConfig{
		target:   target,
		explicit: explicit,
		mode:     mode,
		once:     *once,
		wait:     *wait,
		levelIdx: levelIdx,
		layers:   layers,
		query:    grepQuery,
		filter: record.Filter{
			MinSeverity: record.Levels[levelIdx].Severity,
			Layers:      layers,
			Query:       q,
		},
	}, nil
}

func parseLayerSet(csv string) map[string]bool {
	if strings.TrimSpace(csv) == "" {
		return nil
	}
	out := map[string]bool{}
	for part := range strings.SplitSeq(csv, ",") {
		if s := strings.ToLower(strings.TrimSpace(part)); s != "" {
			out[s] = true
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// permuteArgs lifts flags ahead of positional arguments so both
// `strata --once target` and `strata target --once` parse identically.
func permuteArgs(fs *flag.FlagSet, args []string) []string {
	var flags, pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			pos = append(pos, args[i+1:]...)
			break
		}
		if strings.HasPrefix(a, "-") && a != "-" {
			flags = append(flags, a)
			name := strings.TrimPrefix(strings.TrimPrefix(a, "-"), "-")
			if !strings.Contains(name, "=") {
				if f := fs.Lookup(name); f != nil && !isBoolFlag(f) && i+1 < len(args) {
					i++
					flags = append(flags, args[i])
				}
			}
			continue
		}
		pos = append(pos, a)
	}
	if len(pos) == 0 {
		return flags
	}
	return append(append(flags, "--"), pos...)
}

func isBoolFlag(f *flag.Flag) bool {
	bf, ok := f.Value.(interface{ IsBoolFlag() bool })
	return ok && bf.IsBoolFlag()
}

func resolveTarget(raw string, explicit bool) (vmservice.Target, error) {
	if explicit {
		return vmservice.Resolve(raw)
	}
	return vmservice.ResolveDefault(raw)
}

func dialVM(ctx context.Context, wsURL string) (*vmservice.Client, error) {
	dctx, cancel := context.WithTimeout(ctx, dialTimeout)
	defer cancel()
	return vmservice.Dial(dctx, wsURL)
}

type interruptedErr struct{ cause error }

func (interruptedErr) Error() string   { return "interrupted" }
func (e interruptedErr) Unwrap() error { return e.cause }

func (e runEnv) runCLI(ctx context.Context, cfg cliConfig) error {
	resolved, client, err := e.acquireCLITarget(ctx, cfg)
	if err != nil {
		if ctx.Err() != nil {
			if cfg.once {
				return interruptedErr{ctx.Err()}
			}
			return nil // interrupted while waiting for a live stream target
		}
		return err
	}
	if client != nil {
		defer client.Close()
	}

	switch resolved.Kind {
	case vmservice.TargetStdin:
		return e.replayReader(ctx, e.inReader(), cfg)
	case vmservice.TargetJSONL:
		f, err := os.Open(resolved.Value)
		if err != nil {
			return err
		}
		defer func() { _ = f.Close() }()
		return e.replayReader(ctx, f, cfg)
	default:
		if cfg.once {
			return e.runSnapshot(ctx, client, cfg)
		}
		return e.runStream(ctx, client, cfg)
	}
}

func (e runEnv) acquireCLITarget(ctx context.Context, cfg cliConfig) (vmservice.Target, *vmservice.Client, error) {
	for {
		resolved, err := resolveTarget(cfg.target, cfg.explicit)
		if err == nil {
			if resolved.Kind != vmservice.TargetVMService {
				return resolved, nil, nil
			}
			c, derr := dialVM(ctx, resolved.Value)
			if derr == nil {
				return resolved, c, nil
			}
			err = derr
		}
		if !cfg.wait {
			if errors.Is(err, vmservice.ErrWaiting) {
				return vmservice.Target{}, nil, fmt.Errorf("waiting for %s (pass --wait to poll)", cfg.target)
			}
			return vmservice.Target{}, nil, err
		}
		select {
		case <-ctx.Done():
			return vmservice.Target{}, nil, ctx.Err()
		case <-time.After(e.pollEvery()):
		}
	}
}

func (e runEnv) reportMalformed(n int64) {
	if n > 0 {
		_, _ = fmt.Fprintf(e.errOut(), "strata: skipped %d malformed records\n", n)
	}
}

func (e runEnv) runSnapshot(ctx context.Context, c *vmservice.Client, cfg cliConfig) error {
	// A partial snapshot still prints what it got, then fails: a script must
	// never mistake a missed isolate for one that logged nothing.
	items, err := vmservice.Snapshot(ctx, c)
	if cfg.wait {
		// The service-info file appears before main() reaches configureLogging.
		expired := time.After(e.historyGraceOrDefault())
		for errors.Is(err, vmservice.ErrNoHistory) {
			select {
			case <-ctx.Done():
				return interruptedErr{ctx.Err()}
			case <-expired:
				return noHistoryErr(err)
			case <-time.After(e.pollEvery()):
			}
			items, err = vmservice.Snapshot(ctx, c)
		}
	}
	if errors.Is(err, vmservice.ErrNoHistory) {
		return noHistoryErr(err)
	}
	e.reportMalformed(c.Malformed())
	for _, it := range items {
		if !cfg.filter.Match(it.Rec, "") {
			continue
		}
		if werr := writeRecord(e.stdout, it.Rec, cfg.mode); werr != nil {
			return cleanPipeErr(werr)
		}
	}
	if err != nil && ctx.Err() != nil {
		return interruptedErr{errors.Join(ctx.Err(), err)}
	}
	return err
}

func noHistoryErr(err error) error {
	return fmt.Errorf("%w (likely causes: configureLogging not called yet, a release build, or configureLogging(vmStream: false))", err)
}

func (e runEnv) runStream(ctx context.Context, c *vmservice.Client, cfg cliConfig) error {
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var (
		werr           error
		wroteAny       bool
		pendingRestart bool
	)
	err := vmservice.Stream(sctx, c, vmservice.NewDedup(), func(it vmservice.Item) {
		// Only a session's first record carries Restarted, and the filter may
		// drop it.
		pendingRestart = pendingRestart || it.Restarted
		if werr != nil || !cfg.filter.Match(it.Rec, "") {
			return
		}
		if pendingRestart && wroteAny && cfg.mode == modePlain {
			if _, werr = fmt.Fprintln(e.stdout, "── session restarted ──"); werr != nil {
				cancel()
				return
			}
		}
		pendingRestart = false
		wroteAny = true
		if werr = writeRecord(e.stdout, it.Rec, cfg.mode); werr != nil {
			cancel()
		}
	})
	e.reportMalformed(c.Malformed())
	switch {
	case werr != nil:
		return cleanPipeErr(werr)
	case ctx.Err() != nil:
		return nil
	case errors.Is(err, vmservice.ErrDisconnected):
		// Every record received was written; whether the target exited or
		// crashed is not observable, so the drop is a note, not a failure.
		_, _ = fmt.Fprintln(e.errOut(), "strata: target disconnected")
		return nil
	default:
		return err
	}
}

func (e runEnv) replayReader(ctx context.Context, r io.Reader, cfg cliConfig) error {
	malformed, err := readNDJSON(ctx, r, func(rec record.Record) error {
		if !cfg.filter.Match(rec, "") {
			return nil
		}
		return writeRecord(e.stdout, rec, cfg.mode)
	})
	e.reportMalformed(malformed)
	if err != nil {
		if ctx.Err() != nil {
			if cfg.once {
				return interruptedErr{ctx.Err()}
			}
			return nil
		}
		return cleanPipeErr(err)
	}
	return nil
}

func writeRecord(w io.Writer, r record.Record, mode outputMode) error {
	if mode == modeJSON {
		var buf bytes.Buffer
		buf.Write(r.JSON())
		buf.WriteByte('\n')
		_, err := w.Write(buf.Bytes())
		return err
	}
	_, err := fmt.Fprintln(w, r.Plain())
	return err
}

func cleanPipeErr(err error) error {
	if errors.Is(err, syscall.EPIPE) {
		return nil
	}
	return err
}

// readNDJSON emits each record line of r until EOF, an emit error, or ctx
// ends. A blocked read never delays cancellation: reads run on their own
// goroutine, which is abandoned until r yields or the process exits — an idle
// pipe on stdin would otherwise hold quit or SIGINT hostage.
func readNDJSON(ctx context.Context, r io.Reader, emit func(record.Record) error) (int64, error) {
	type chunk struct {
		line []byte
		err  error
	}
	chunks := make(chan chunk)
	go func() {
		br := bufio.NewReaderSize(r, 64*1024)
		for {
			line, err := br.ReadBytes('\n')
			select {
			case chunks <- chunk{line, err}:
			case <-ctx.Done():
				return
			}
			if err != nil {
				return
			}
		}
	}()

	var malformed int64
	for {
		var c chunk
		select {
		case <-ctx.Done():
			return malformed, ctx.Err()
		case c = <-chunks:
		}
		line, rerr := c.line, c.err
		trimmed := bytes.TrimSpace(line)
		if len(trimmed) > 0 {
			rec, derr := record.Decode(trimmed)
			if derr != nil {
				malformed++
			} else if err := emit(rec); err != nil {
				return malformed, err
			}
		}
		if rerr != nil {
			if errors.Is(rerr, io.EOF) {
				return malformed, nil
			}
			return malformed, rerr
		}
	}
}
