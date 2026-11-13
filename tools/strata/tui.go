package main

import (
	"context"
	"errors"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/esenmx/stratalog/tools/strata/internal/ui"
	"github.com/esenmx/stratalog/tools/strata/internal/vmservice"
)

const pollInterval = 500 * time.Millisecond

func runTUI(ctx context.Context, target string) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	p := tea.NewProgram(ui.New(target), tea.WithContext(ctx))
	done := make(chan struct{})
	go func() {
		defer close(done)
		connectLoop(ctx, target, p.Send)
	}()

	_, err := p.Run()
	cancel()
	<-done
	if errors.Is(err, tea.ErrProgramKilled) && ctx.Err() != nil {
		return nil // interrupted by a signal
	}
	return err
}

// connectLoop resolves target, connects and streams until ctx ends. A
// missing target or dropped connection is retried every [pollInterval];
// records and dedup state survive reconnects.
func connectLoop(ctx context.Context, target string, send func(tea.Msg)) {
	d := vmservice.NewDedup()
	var malformed int64
	for ctx.Err() == nil {
		wsURL, err := vmservice.ResolveTarget(target)
		switch {
		case errors.Is(err, vmservice.ErrWaiting):
			send(ui.ConnMsg(ui.Waiting, target, malformed))
		case err != nil:
			send(ui.ConnMsg(ui.Disconnected, err.Error(), malformed))
		default:
			malformed += stream(ctx, wsURL, d, malformed, send)
		}
		select {
		case <-ctx.Done():
		case <-time.After(pollInterval):
		}
	}
}

// stream runs one connection and returns how many malformed events it
// skipped; base is the count from earlier connections.
func stream(ctx context.Context, wsURL string, d *vmservice.Dedup, base int64, send func(tea.Msg)) int64 {
	c, err := vmservice.Dial(ctx, wsURL)
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
