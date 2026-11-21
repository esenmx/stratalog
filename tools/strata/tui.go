package main

import (
	"context"
	"errors"
	"io"
	"os"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/esenmx/stratalog/tools/strata/record"
	"github.com/esenmx/stratalog/tools/strata/ui"
	"github.com/esenmx/stratalog/tools/strata/vmservice"
)

const pollInterval = 500 * time.Millisecond

func (e runEnv) runTUI(parentCtx context.Context, cfg cliConfig) error {
	ctx, cancel := context.WithCancel(parentCtx)
	defer cancel()

	initial, initErr := resolveTarget(cfg.target, cfg.explicit)
	isReplay := initErr == nil && (initial.Kind == vmservice.TargetJSONL || initial.Kind == vmservice.TargetStdin)

	model := ui.NewWithOptions(ui.Options{
		Target: cfg.target,
		Level:  cfg.levelIdx,
		Layers: cfg.layers,
		Query:  cfg.query,
		Replay: isReplay,
	})

	progOpts := []tea.ProgramOption{tea.WithContext(ctx)}
	if initErr == nil && initial.Kind == vmservice.TargetStdin {
		tty, err := os.Open("/dev/tty")
		if err != nil {
			return err
		}
		defer func() { _ = tty.Close() }()
		progOpts = append(progOpts, tea.WithInput(tty))
	}

	p := tea.NewProgram(model, progOpts...)
	done := make(chan struct{})
	go func() {
		defer close(done)
		switch {
		case initErr == nil && initial.Kind == vmservice.TargetStdin:
			replayIntoTUI(ctx, e.stdin, cfg.target, p.Send)
		case initErr == nil && initial.Kind == vmservice.TargetJSONL:
			replayFileIntoTUI(ctx, initial.Value, p.Send)
		default:
			connectLoop(ctx, cfg.target, cfg.explicit, e.poll, p.Send)
		}
	}()

	_, err := p.Run()
	cancel()
	<-done
	if errors.Is(err, tea.ErrProgramKilled) && parentCtx.Err() != nil {
		return nil // interrupted by a signal
	}
	return err
}

func replayFileIntoTUI(ctx context.Context, path string, send func(tea.Msg)) {
	f, err := os.Open(path)
	if err != nil {
		send(ui.ConnMsg(ui.Disconnected, err.Error(), 0))
		return
	}
	defer func() { _ = f.Close() }()
	replayIntoTUI(ctx, f, path, send)
}

func replayIntoTUI(ctx context.Context, r io.Reader, label string, send func(tea.Msg)) {
	malformed, err := readNDJSON(ctx, r, func(rec record.Record) error {
		send(ui.RecordMsg(vmservice.Item{Rec: rec}, 0))
		return nil
	})
	if err != nil && ctx.Err() == nil {
		send(ui.ConnMsg(ui.Disconnected, err.Error(), malformed))
		return
	}
	send(ui.ConnMsg(ui.Replaying, label, malformed))
}

// connectLoop resolves target, connects and streams until ctx ends. A
// missing target or dropped connection is retried every poll; records and
// dedup state survive reconnects.
func connectLoop(ctx context.Context, target string, explicit bool, poll time.Duration, send func(tea.Msg)) {
	d := vmservice.NewDedup()
	var malformed int64
	for ctx.Err() == nil {
		resolved, err := resolveTarget(target, explicit)
		switch {
		case errors.Is(err, vmservice.ErrWaiting):
			send(ui.ConnMsg(ui.Waiting, target, malformed))
		case err != nil:
			send(ui.ConnMsg(ui.Disconnected, err.Error(), malformed))
		case resolved.Kind == vmservice.TargetJSONL:
			replayFileIntoTUI(ctx, resolved.Value, send)
			return
		default:
			malformed += stream(ctx, resolved.Value, d, malformed, send)
		}
		select {
		case <-ctx.Done():
		case <-time.After(poll):
		}
	}
}

// stream runs one connection and returns how many malformed events it
// skipped; base is the count from earlier connections.
func stream(ctx context.Context, wsURL string, d *vmservice.Dedup, base int64, send func(tea.Msg)) int64 {
	c, err := dialVM(ctx, wsURL)
	if err != nil {
		send(ui.ConnMsg(ui.Disconnected, "app not reachable, retrying", base))
		return 0
	}
	defer c.Close()
	send(ui.ConnMsg(ui.Connected, wsURL, base))
	err = vmservice.Stream(ctx, c, d, func(it vmservice.Item) {
		send(ui.RecordMsg(it, base+c.Malformed()))
	})
	if ctx.Err() == nil {
		reason := "connection lost, retrying"
		if err != nil && !errors.Is(err, vmservice.ErrClosed) {
			reason = err.Error()
		}
		send(ui.ConnMsg(ui.Disconnected, reason, base+c.Malformed()))
	}
	return c.Malformed()
}
