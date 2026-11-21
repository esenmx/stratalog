package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/esenmx/stratalog/tools/strata/record"
	"github.com/esenmx/stratalog/tools/strata/ui"
	"github.com/esenmx/stratalog/tools/strata/vmservice"
)

// runConnectLoop runs connectLoop on target, polling every millisecond, and
// returns what it sent once done reports true or the loop returns.
func runConnectLoop(t *testing.T, target string, done func([]tea.Msg) bool) []tea.Msg {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	var mu sync.Mutex
	var msgs []tea.Msg
	connectLoop(ctx, target, true, time.Millisecond, func(m tea.Msg) {
		mu.Lock()
		defer mu.Unlock()
		msgs = append(msgs, m)
		if done(msgs) {
			cancel()
		}
	})
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		t.Fatalf("connectLoop timed out after sending %d messages", len(msgs))
	}
	mu.Lock()
	defer mu.Unlock()
	return msgs
}

func TestConnectLoopKeepsDedupAcrossReconnects(t *testing.T) {
	srv := fakeVMServer(t, restartHistory[:1], false) // closes after each history reply
	ws, err := vmservice.Resolve(srv)
	if err != nil {
		t.Fatal(err)
	}
	connected := ui.ConnMsg(ui.Connected, ws.Value, 0)
	records := reflect.TypeOf(ui.RecordMsg(vmservice.Item{}, 0))
	count := func(msgs []tea.Msg, match func(tea.Msg) bool) (n int) {
		for _, m := range msgs {
			if match(m) {
				n++
			}
		}
		return n
	}
	msgs := runConnectLoop(t, srv, func(msgs []tea.Msg) bool {
		return count(msgs, func(m tea.Msg) bool { return reflect.DeepEqual(m, connected) }) == 3
	})
	if n := count(msgs, func(m tea.Msg) bool { return reflect.TypeOf(m) == records }); n != 1 {
		t.Errorf("3 connections to one session sent %d records, want its 1 history record once", n)
	}
}

func TestConnectLoopWaitsForAMissingTarget(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing.vmservice")
	msgs := runConnectLoop(t, missing, func([]tea.Msg) bool { return true })
	if want := ui.ConnMsg(ui.Waiting, missing, 0); !reflect.DeepEqual(msgs[0], want) {
		t.Errorf("first message = %#v, want %#v", msgs[0], want)
	}
}

func TestConnectLoopReplaysACaptureFileOnce(t *testing.T) {
	line := `{"v":1,"seq":1,"time":"2026-04-14T06:04:05Z","level":"info","severity":200,"layer":"App","message":"captured"}`
	capture := filepath.Join(t.TempDir(), "capture.jsonl")
	if err := os.WriteFile(capture, []byte(line+"\n{malformed\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	rec, err := record.Decode([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	msgs := runConnectLoop(t, capture, func([]tea.Msg) bool { return false })
	if want := []tea.Msg{ui.RecordMsg(vmservice.Item{Rec: rec}, 0), ui.ConnMsg(ui.Replaying, capture, 1)}; !reflect.DeepEqual(msgs, want) {
		t.Errorf("sent %#v, want %#v", msgs, want)
	}
}
