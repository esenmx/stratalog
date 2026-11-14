package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/esenmx/stratalog/tools/strata/vmservice"
)

func TestParseCLIPermutationAndModes(t *testing.T) {
	cfg, err := parseCLI([]string{"session.jsonl", "--once", "-l", "warning", "-L", "Network,Storage", "-g", "timeout"}, true, io.Discard)
	if err != nil {
		t.Fatalf("parseCLI: %v", err)
	}
	if cfg.target != "session.jsonl" || !cfg.explicit || !cfg.once || cfg.mode != modePlain {
		t.Fatalf("unexpected cfg: %+v", cfg)
	}
	if !cfg.layers["network"] || !cfg.layers["storage"] {
		t.Fatalf("layers = %v, want network+storage", cfg.layers)
	}

	// Non-TTY stdout auto-selects plain mode even without --plain.
	nonTTY, err := parseCLI(nil, false, io.Discard)
	if err != nil {
		t.Fatalf("parseCLI non-TTY: %v", err)
	}
	if nonTTY.mode != modePlain {
		t.Errorf("non-TTY mode = %v, want modePlain", nonTTY.mode)
	}

	// TTY stdout with no CLI output flags selects TUI mode.
	ttyCfg, err := parseCLI(nil, true, io.Discard)
	if err != nil {
		t.Fatalf("parseCLI TTY: %v", err)
	}
	if ttyCfg.mode != modeTUI {
		t.Errorf("TTY mode = %v, want modeTUI", ttyCfg.mode)
	}

	// Stdin "-" after or before flags remains positional.
	stdinCfg, err := parseCLI([]string{"-", "--json"}, true, io.Discard)
	if err != nil {
		t.Fatalf("parseCLI stdin: %v", err)
	}
	if stdinCfg.target != "-" || stdinCfg.mode != modeJSON {
		t.Errorf("stdin cfg = %+v", stdinCfg)
	}

	if _, err := parseCLI([]string{"--plain", "--json"}, false, io.Discard); err == nil {
		t.Error("expected error combining --plain and --json")
	}
	if _, err := parseCLI([]string{"-l", "bogus"}, false, io.Discard); err == nil {
		t.Error("expected error on unknown level")
	}
}

func TestOnceJSONAndReplayFiltering(t *testing.T) {
	srv := fakeVMServer(t, []map[string]any{
		{
			"v": 1, "seq": 1, "time": "2026-04-14T06:04:05Z",
			"level": "trace", "severity": 0, "layer": "State",
			"message": "cart tick",
		},
		{
			"v": 1, "seq": 2, "time": "2026-04-14T06:04:06Z",
			"level": "info", "severity": 200, "layer": "Network",
			"message": "GET /users/42",
			"data":    map[string]any{"status": 200, "name": "Jane"},
		},
		{
			"v": 1, "seq": 3, "time": "2026-04-14T06:04:07Z",
			"level": "error", "severity": 500, "layer": "Storage",
			"message": "insert failed",
			"error":   "SqliteException(787): FOREIGN KEY constraint failed",
		},
	}, false)

	var jsonBuf, errBuf bytes.Buffer
	env := runEnv{stdout: &jsonBuf, stderr: &errBuf, isTTY: false}
	// Flags intentionally placed AFTER target to verify end-to-end arg permutation.
	if err := env.run(t.Context(), []string{srv, "--once", "--json"}); err != nil {
		t.Fatalf("run --once --json: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(jsonBuf.String()), "\n")
	if len(lines) != 3 {
		t.Fatalf("got %d JSON lines, want 3:\n%s", len(lines), jsonBuf.String())
	}

	// Save capture to .jsonl (plus one malformed line) and replay with filters.
	capture := filepath.Join(t.TempDir(), "capture.jsonl")
	raw := jsonBuf.String() + "{malformed\n"
	if err := os.WriteFile(capture, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}

	var plainBuf, replayErr bytes.Buffer
	replayEnv := runEnv{stdout: &plainBuf, stderr: &replayErr, isTTY: false}
	if err := replayEnv.run(t.Context(), []string{capture, "-l", "info"}); err != nil {
		t.Fatalf("replay .jsonl: %v", err)
	}
	out := plainBuf.String()
	if strings.Contains(out, "cart tick") {
		t.Errorf("trace record leaked past -l info:\n%s", out)
	}
	if !strings.Contains(out, "GET /users/42") || !strings.Contains(out, "FOREIGN KEY constraint failed") {
		t.Errorf("expected info + error with inline error text:\n%s", out)
	}
	if !strings.Contains(replayErr.String(), "skipped 1 malformed") {
		t.Errorf("stderr = %q, want malformed notice", replayErr.String())
	}

	// Replay from stdin "-" with -L Storage and -g foreign.
	plainBuf.Reset()
	stdinEnv := runEnv{
		stdin:  strings.NewReader(jsonBuf.String()),
		stdout: &plainBuf,
		stderr: io.Discard,
		isTTY:  true, // --plain forces CLI even on TTY
	}
	if err := stdinEnv.run(t.Context(), []string{"-", "--plain", "-L", "storage", "-g", "foreign"}); err != nil {
		t.Fatalf("stdin replay: %v", err)
	}
	if got := strings.TrimSpace(plainBuf.String()); !strings.Contains(got, "insert failed") || strings.Contains(got, "GET /users/42") {
		t.Errorf("stdin filtered output = %q", got)
	}
}

func TestWaitPollsUntilTargetFileAppears(t *testing.T) {
	srv := fakeVMServer(t, []map[string]any{
		{
			"v": 1, "seq": 1, "time": "2026-04-14T06:04:05Z",
			"level": "info", "severity": 200, "layer": "App",
			"message": "booted after wait",
		},
	}, false)

	targetFile := filepath.Join(t.TempDir(), ".flutter.vmservice")
	go func() {
		time.Sleep(30 * time.Millisecond)
		_ = os.WriteFile(targetFile, []byte(srv+"\n"), 0o600)
	}()

	var out bytes.Buffer
	env := runEnv{stdout: &out, stderr: io.Discard, poll: 10 * time.Millisecond}
	if err := env.run(t.Context(), []string{"--wait", "--once", targetFile}); err != nil {
		t.Fatalf("run --wait --once: %v", err)
	}
	if !strings.Contains(out.String(), "booted after wait") {
		t.Errorf("out = %q, want 'booted after wait'", out.String())
	}
}

type epipeAfterOneWriter struct {
	calls atomic.Int32
}

func (w *epipeAfterOneWriter) Write(p []byte) (int, error) {
	if w.calls.Add(1) > 1 {
		return 0, syscall.EPIPE
	}
	return len(p), nil
}

func TestStreamBrokenPipeCancelsCleanly(t *testing.T) {
	srv := fakeVMServer(t, []map[string]any{
		{"v": 1, "seq": 1, "time": "2026-04-14T06:04:05Z", "level": "info", "severity": 200, "layer": "App", "message": "one"},
		{"v": 1, "seq": 2, "time": "2026-04-14T06:04:06Z", "level": "info", "severity": 200, "layer": "App", "message": "two"},
	}, true /* keepOpen */)

	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()

	env := runEnv{stdout: &epipeAfterOneWriter{}, stderr: io.Discard}
	if err := env.run(ctx, []string{"--plain", srv}); err != nil {
		t.Fatalf("broken pipe returned error %v, want nil", err)
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		t.Fatal("broken pipe hung until context deadline instead of canceling stream")
	}
}

func fakeVMServer(t *testing.T, history []map[string]any, keepOpen bool) string {
	t.Helper()
	return fakeVMServerHidingHistory(t, history, keepOpen, 0)
}

// fakeVMServerHidingHistory is fakeVMServer whose isolate registers the
// history extension only from its getIsolate call number hiddenFor+1 on;
// negative hides it for good.
func fakeVMServerHidingHistory(t *testing.T, history []map[string]any, keepOpen bool, hiddenFor int32) string {
	t.Helper()
	var inspected atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer func() { _ = conn.CloseNow() }()
		ctx := r.Context()
		for {
			_, raw, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var req struct {
				ID     string `json:"id"`
				Method string `json:"method"`
			}
			if json.Unmarshal(raw, &req) != nil {
				continue
			}
			reply := func(res any) {
				b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": res})
				_ = conn.Write(ctx, websocket.MessageText, b)
			}
			switch req.Method {
			case "streamListen":
				reply(map[string]any{"type": "Success"})
			case "getVM":
				reply(map[string]any{
					"startTime": 1000,
					"pid":       42,
					"isolates":  []map[string]any{{"id": "isolates/1", "name": "main"}},
				})
			case "getIsolate":
				rpcs := []string{}
				if n := inspected.Add(1); hiddenFor >= 0 && n > hiddenFor {
					rpcs = append(rpcs, vmservice.HistoryExtension)
				}
				reply(map[string]any{"extensionRPCs": rpcs})
			case vmservice.HistoryExtension:
				reply(map[string]any{"records": history})
				if !keepOpen {
					_ = conn.Close(websocket.StatusNormalClosure, "done")
					return
				}
			}
		}
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestWaitInterruptedExitsCleanly(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing.vmservice")
	for _, args := range [][]string{
		{"--plain", "--wait", missing},
		{"--once", "--json", "--wait", missing},
	} {
		t.Run(strings.Join(args[:len(args)-1], " "), func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			cancel() // SIGINT before the target ever appears
			env := runEnv{stdout: io.Discard, stderr: io.Discard, poll: time.Millisecond}
			if err := env.run(ctx, args); err != nil {
				t.Errorf("run %q after interrupt = %v, want nil", args, err)
			}
		})
	}
}

func TestStdinReplayStopsOnInterruptWhileProducerIdle(t *testing.T) {
	pr, pw := io.Pipe()
	t.Cleanup(func() { _ = pw.Close() })
	go func() {
		_, _ = io.WriteString(pw, `{"v":1,"seq":1,"time":"2026-04-14T06:04:05Z","level":"info","severity":200,"layer":"App","message":"first"}`+"\n")
		// The producer then stays open and silent.
	}()

	ctx, cancel := context.WithCancel(t.Context())
	var out syncBuffer
	env := runEnv{stdin: pr, stdout: &out, stderr: io.Discard}
	done := make(chan error, 1)
	go func() { done <- env.run(ctx, []string{"--plain", "-"}) }()

	deadline := time.After(3 * time.Second)
	for !strings.Contains(out.String(), "first") {
		select {
		case <-deadline:
			t.Fatal("first record never replayed")
		case <-time.After(time.Millisecond):
		}
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("run after interrupt = %v, want nil", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("stdin replay ignored the interrupt while the producer was idle")
	}
}

// syncBuffer is a bytes.Buffer safe to read while another goroutine writes.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func TestReportErrorEscapesEveryLine(t *testing.T) {
	var out bytes.Buffer
	reportError(&out, errors.Join(
		errors.New("isolate w\x1b]0;pwn\x07 (isolates/2) history: timeout"),
		errors.New("isolate b (isolates/3) history: closed"),
	))
	want := "strata: isolate w\\x1b]0;pwn\\x07 (isolates/2) history: timeout\n" +
		"strata: isolate b (isolates/3) history: closed\n"
	if out.String() != want {
		t.Errorf("reportError wrote %q, want %q", out.String(), want)
	}
}

func TestOncePrintsReachableIsolatesThenFailsNamingTheMissedOne(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer func() { _ = conn.CloseNow() }()
		ctx := r.Context()
		for {
			_, raw, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var req struct {
				ID     string `json:"id"`
				Method string `json:"method"`
				Params struct {
					IsolateID string `json:"isolateId"`
				} `json:"params"`
			}
			if json.Unmarshal(raw, &req) != nil {
				continue
			}
			msg := map[string]any{"jsonrpc": "2.0", "id": req.ID}
			switch {
			case req.Method == "getVM":
				msg["result"] = map[string]any{"startTime": 1000, "isolates": []map[string]any{
					{"id": "isolates/1", "name": "main"},
					{"id": "isolates/2", "name": "drift"},
				}}
			case req.Method == "getIsolate":
				msg["result"] = map[string]any{"extensionRPCs": []string{vmservice.HistoryExtension}}
			case req.Params.IsolateID == "isolates/1":
				msg["result"] = map[string]any{"records": []map[string]any{{
					"v": 1, "seq": 1, "time": "2026-04-14T06:04:05Z",
					"level": "info", "severity": 200, "layer": "App", "message": "reachable",
				}}}
			default:
				msg["error"] = map[string]any{"code": 113, "message": "isolate is paused"}
			}
			b, _ := json.Marshal(msg)
			_ = conn.Write(ctx, websocket.MessageText, b)
		}
	}))
	t.Cleanup(srv.Close)

	var out bytes.Buffer
	env := runEnv{stdout: &out, stderr: io.Discard}
	err := env.run(t.Context(), []string{"--once", "--plain", srv.URL})
	if !strings.Contains(out.String(), "reachable") {
		t.Errorf("stdout = %q, want the reachable isolate's record", out.String())
	}
	if err == nil || !strings.Contains(err.Error(), "drift") {
		t.Errorf("run --once = %v, want an error naming the missed drift isolate", err)
	}
}

func TestOnceWithoutHistoryExtensionFailsUnlessItAppearsWithinGrace(t *testing.T) {
	booted := []map[string]any{{
		"v": 1, "seq": 1, "time": "2026-04-14T06:04:05Z",
		"level": "info", "severity": 200, "layer": "App", "message": "booted",
	}}
	for name, tc := range map[string]struct {
		history   []map[string]any
		hiddenFor int32
		args      []string
		wantOut   string
		wantErr   bool
	}{
		"no --wait fails at once": {
			history: booted, hiddenFor: -1,
			args:    []string{"--once", "--json"},
			wantErr: true,
		},
		"--wait gives up after the grace period": {
			history: booted, hiddenFor: -1,
			args:    []string{"--once", "--json", "--wait"},
			wantErr: true,
		},
		"--wait snapshots once the extension registers": {
			history: booted, hiddenFor: 3,
			args:    []string{"--once", "--plain", "--wait"},
			wantOut: "booted",
		},
		"an extension with zero records is an empty success": {
			history: nil, hiddenFor: 0,
			args: []string{"--once", "--json"},
		},
	} {
		t.Run(name, func(t *testing.T) {
			srv := fakeVMServerHidingHistory(t, tc.history, false, tc.hiddenFor)
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()

			var out bytes.Buffer
			env := runEnv{stdout: &out, stderr: io.Discard, poll: 5 * time.Millisecond, historyGrace: 200 * time.Millisecond}
			err := env.run(ctx, append(tc.args, srv))
			if ctx.Err() != nil {
				t.Fatal("run outlived its context instead of a bounded grace period")
			}
			switch {
			case tc.wantErr && (err == nil || !strings.Contains(err.Error(), "configureLogging")):
				t.Errorf("run = %v, want an error naming configureLogging as a likely cause", err)
			case !tc.wantErr && err != nil:
				t.Errorf("run = %v, want success", err)
			}
			if got := strings.TrimSpace(out.String()); !strings.Contains(got, tc.wantOut) || (tc.wantOut == "" && got != "") {
				t.Errorf("stdout = %q, want %q", got, tc.wantOut)
			}
		})
	}
}

func TestPlainStreamMarksRestartWhoseFirstRecordIsFiltered(t *testing.T) {
	srv := fakeVMServer(t, []map[string]any{
		{"v": 1, "seq": 5, "time": "2026-04-14T06:04:05Z", "level": "error", "severity": 500, "layer": "App", "message": "old session"},
		{"v": 1, "seq": 1, "time": "2026-04-14T06:05:00Z", "level": "trace", "severity": 0, "layer": "App", "message": "boot trace"},
		{"v": 1, "seq": 2, "time": "2026-04-14T06:05:01Z", "level": "error", "severity": 500, "layer": "App", "message": "new session error"},
	}, false)

	var out bytes.Buffer
	env := runEnv{stdout: &out, stderr: io.Discard}
	if err := env.run(t.Context(), []string{"--plain", "-l", "info", srv}); err != nil {
		t.Fatalf("run --plain -l info: %v", err)
	}
	var got []string
	for line := range strings.Lines(out.String()) {
		switch {
		case strings.Contains(line, "session restarted"):
			got = append(got, "divider")
		case strings.Contains(line, "old session"):
			got = append(got, "old")
		case strings.Contains(line, "new session error"):
			got = append(got, "new")
		default:
			got = append(got, line)
		}
	}
	if want := []string{"old", "divider", "new"}; !slices.Equal(got, want) {
		t.Errorf("plain output = %q, want %q:\n%s", got, want, out.String())
	}
}

// fakeVMServerDroppingAt serves one history record and resets the connection,
// with no WebSocket close frame, when the client calls dropAt: on getIsolate
// before answering it, on the history extension right after answering it.
func fakeVMServerDroppingAt(t *testing.T, dropAt string) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer func() { _ = conn.CloseNow() }()
		ctx := r.Context()
		for {
			_, raw, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var req struct {
				ID     string `json:"id"`
				Method string `json:"method"`
			}
			if json.Unmarshal(raw, &req) != nil {
				continue
			}
			reply := func(res any) {
				b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": res})
				_ = conn.Write(ctx, websocket.MessageText, b)
			}
			switch req.Method {
			case "streamListen":
				reply(map[string]any{"type": "Success"})
			case "getVM":
				reply(map[string]any{
					"startTime": 1000,
					"pid":       42,
					"isolates":  []map[string]any{{"id": "isolates/1", "name": "main"}},
				})
			case "getIsolate":
				if dropAt == req.Method {
					return
				}
				reply(map[string]any{"extensionRPCs": []string{vmservice.HistoryExtension}})
			case vmservice.HistoryExtension:
				reply(map[string]any{"records": []map[string]any{
					{"v": 1, "seq": 1, "time": "2026-04-14T06:04:05Z", "level": "info", "severity": 200, "layer": "App", "message": "one"},
				}})
				if dropAt == req.Method {
					return
				}
			}
		}
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestPlainStreamTreatsTargetDisconnectAsCleanExitWithNote(t *testing.T) {
	srv := fakeVMServerDroppingAt(t, vmservice.HistoryExtension)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()

	var out, errOut bytes.Buffer
	env := runEnv{stdout: &out, stderr: &errOut}
	if err := env.run(ctx, []string{"--plain", srv}); err != nil {
		t.Fatalf("run --plain after the target dropped the connection: %v, want nil", err)
	}
	if !strings.Contains(out.String(), "one") {
		t.Errorf("stdout = %q, want the record delivered before the drop", out.String())
	}
	if got, want := errOut.String(), "strata: target disconnected\n"; got != want {
		t.Errorf("stderr = %q, want %q", got, want)
	}
}

func TestPlainStreamFailsWhenConnectionDropsBeforeSubscribing(t *testing.T) {
	srv := fakeVMServerDroppingAt(t, "getIsolate")
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()

	var errOut bytes.Buffer
	env := runEnv{stdout: io.Discard, stderr: &errOut}
	err := env.run(ctx, []string{"--plain", srv})
	if !errors.Is(err, vmservice.ErrClosed) {
		t.Fatalf("run --plain with a drop during getIsolate: %v, want vmservice.ErrClosed", err)
	}
	if errOut.Len() != 0 {
		t.Errorf("stderr = %q, want nothing: run's error carries the report", errOut.String())
	}
}

func TestPlainStreamDisconnectWithoutStderrDoesNotPanic(t *testing.T) {
	srv := fakeVMServerDroppingAt(t, vmservice.HistoryExtension)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()

	var out bytes.Buffer
	if err := (runEnv{stdout: &out}).run(ctx, []string{"--plain", srv}); err != nil {
		t.Fatalf("run --plain with no stderr set: %v, want nil", err)
	}
}
