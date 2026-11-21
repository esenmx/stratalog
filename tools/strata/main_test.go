package main

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"io"
	"maps"
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

	"github.com/esenmx/stratalog/tools/strata/record"
	"github.com/esenmx/stratalog/tools/strata/vmservice"
)

func TestParseCLIPermutationAndModes(t *testing.T) {
	for name, tc := range map[string]struct {
		args    []string
		tty     bool
		target  string // "" = the default, not explicit
		mode    outputMode
		once    bool
		level   int
		layers  []string
		wantErr string
	}{
		"flags after the target": {
			args: []string{"session.jsonl", "--once", "-l", "warning", "-L", "Network,Storage", "-g", "timeout"}, tty: true,
			target: "session.jsonl", mode: modePlain, once: true, level: 5, layers: []string{"network", "storage"},
		},
		"non-TTY stdout picks plain":  {mode: modePlain},
		"TTY stdout picks the TUI":    {tty: true, mode: modeTUI},
		"stdin dash stays positional": {args: []string{"-", "--json"}, tty: true, target: "-", mode: modeJSON},
		"-- ends the flags":           {args: []string{"--json", "--", "capture.jsonl"}, target: "capture.jsonl", mode: modeJSON},
		"--plain and --json conflict": {args: []string{"--plain", "--json"}, wantErr: "cannot combine"},
		"unknown level":               {args: []string{"-l", "bogus"}, wantErr: "unknown level"},
		"two targets":                 {args: []string{"a.jsonl", "b.jsonl"}, wantErr: "at most one target"},
	} {
		t.Run(name, func(t *testing.T) {
			cfg, err := parseCLI(tc.args, tc.tty, io.Discard)
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("parseCLI(%q) = %v, want an error containing %q", tc.args, err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseCLI(%q): %v", tc.args, err)
			}
			if cfg.target != cmp.Or(tc.target, defaultTarget) || cfg.explicit != (tc.target != "") || cfg.mode != tc.mode || cfg.once != tc.once || cfg.levelIdx != tc.level {
				t.Errorf("parseCLI(%q) = %+v", tc.args, cfg)
			}
			if got := slices.Sorted(maps.Keys(cfg.layers)); !slices.Equal(got, tc.layers) {
				t.Errorf("layers = %v, want %v", got, tc.layers)
			}
		})
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
	return serveVM(t, func(req vmReq) (map[string]any, vmEnd) {
		switch req.method {
		case "streamListen":
			return result(map[string]any{"type": "Success"}), vmKeep
		case "getVM":
			return result(mainVM), vmKeep
		case "getIsolate":
			rpcs := []string{}
			if n := inspected.Add(1); hiddenFor >= 0 && n > hiddenFor {
				rpcs = append(rpcs, vmservice.HistoryExtension)
			}
			return result(map[string]any{"extensionRPCs": rpcs}), vmKeep
		case vmservice.HistoryExtension:
			end := vmClose
			if keepOpen {
				end = vmKeep
			}
			return result(map[string]any{"records": history}), end
		}
		return nil, vmKeep
	})
}

// vmEnd is how a fake VM service carries on after answering a request.
type vmEnd int

const (
	vmKeep  vmEnd = iota
	vmClose       // close with a normal WebSocket closure
	vmDrop        // reset the connection with no close frame
)

// vmReq is one JSON-RPC request a fake VM service received.
type vmReq struct{ method, isolate string }

var mainVM = map[string]any{"startTime": 1000, "pid": 42, "isolates": []map[string]any{{"id": "isolates/1", "name": "main"}}}

func result(v any) map[string]any { return map[string]any{"result": v} }

// twoIsolates is a getVM reply listing main and a second isolate named name.
func twoIsolates(name string) map[string]any {
	return result(map[string]any{"startTime": 1000, "isolates": []map[string]any{
		{"id": "isolates/1", "name": "main"},
		{"id": "isolates/2", "name": name},
	}})
}

// serveVM serves a fake VM service over WebSocket JSON-RPC: handle answers
// each request with a message holding "result" or "error" (nil sends
// nothing), then says whether the connection stays, closes or drops.
func serveVM(t *testing.T, handle func(vmReq) (map[string]any, vmEnd)) string {
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
				Params struct {
					IsolateID string `json:"isolateId"`
				} `json:"params"`
			}
			if json.Unmarshal(raw, &req) != nil {
				continue
			}
			msg, end := handle(vmReq{req.Method, req.Params.IsolateID})
			if msg != nil {
				msg["jsonrpc"], msg["id"] = "2.0", req.ID
				b, _ := json.Marshal(msg)
				_ = conn.Write(ctx, websocket.MessageText, b)
			}
			switch end {
			case vmClose:
				_ = conn.Close(websocket.StatusNormalClosure, "done")
				return
			case vmDrop:
				return
			}
		}
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestWaitInterruptedExitsCleanlyOnlyWhenStreaming(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing.vmservice")
	ctx, cancel := context.WithCancel(t.Context())
	cancel() // SIGINT before the target ever appears
	env := runEnv{stdout: io.Discard, stderr: io.Discard, poll: time.Millisecond}
	if err := env.run(ctx, []string{"--plain", "--wait", missing}); err != nil {
		t.Errorf("stream --wait after interrupt = %v, want nil", err)
	}
	if err := env.run(ctx, []string{"--once", "--json", "--wait", missing}); !errors.Is(err, context.Canceled) || err.Error() != "interrupted" {
		t.Errorf("--once --wait after interrupt = %v, want interrupted wrapping context.Canceled", err)
	}
}

func TestOnceInterruptedMidSnapshotOrHistoryPollFails(t *testing.T) {
	t.Run("during history poll", func(t *testing.T) {
		srv := fakeVMServerHidingHistory(t, nil, false, -1)
		ctx, cancel := context.WithCancel(t.Context())
		time.AfterFunc(15*time.Millisecond, cancel)

		env := runEnv{stdout: io.Discard, stderr: io.Discard, poll: 2 * time.Millisecond, historyGrace: 5 * time.Second}
		if err := env.run(ctx, []string{"--once", "--json", "--wait", srv}); !errors.Is(err, context.Canceled) || err.Error() != "interrupted" {
			t.Errorf("--once --wait interrupted during history poll = %v, want interrupted wrapping context.Canceled", err)
		}
	})

	t.Run("mid multi-isolate snapshot", func(t *testing.T) {
		ctx, cancel := context.WithCancel(t.Context())
		srv := serveVM(t, func(req vmReq) (map[string]any, vmEnd) {
			switch {
			case req.method == "getVM":
				return twoIsolates("worker"), vmKeep
			case req.method == "getIsolate":
				return result(map[string]any{"extensionRPCs": []string{vmservice.HistoryExtension}}), vmKeep
			case req.isolate == "isolates/1":
				return result(map[string]any{"records": []map[string]any{{
					"v": 1, "seq": 1, "time": "2026-04-14T06:04:05Z",
					"level": "info", "severity": 200, "layer": "App", "message": "partial-ok",
				}}}), vmKeep
			}
			cancel()
			return nil, vmDrop
		})

		var out bytes.Buffer
		env := runEnv{stdout: &out, stderr: io.Discard}
		err := env.run(ctx, []string{"--once", "--plain", srv})
		if !errors.Is(err, context.Canceled) || err.Error() != "interrupted" {
			t.Fatalf("--once interrupted mid-snapshot = %v (stdout = %q), want interrupted wrapping context.Canceled", err, out.String())
		}
	})
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
	srv := serveVM(t, func(req vmReq) (map[string]any, vmEnd) {
		switch {
		case req.method == "getVM":
			return twoIsolates("drift"), vmKeep
		case req.method == "getIsolate":
			return result(map[string]any{"extensionRPCs": []string{vmservice.HistoryExtension}}), vmKeep
		case req.isolate == "isolates/1":
			return result(map[string]any{"records": []map[string]any{{
				"v": 1, "seq": 1, "time": "2026-04-14T06:04:05Z",
				"level": "info", "severity": 200, "layer": "App", "message": "reachable",
			}}}), vmKeep
		}
		return map[string]any{"error": map[string]any{"code": 113, "message": "isolate is paused"}}, vmKeep
	})

	var out bytes.Buffer
	env := runEnv{stdout: &out, stderr: io.Discard}
	err := env.run(t.Context(), []string{"--once", "--plain", srv})
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
		grace     time.Duration // zero: the default
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
			history: booted, hiddenFor: -1, grace: 200 * time.Millisecond,
			args:    []string{"--once", "--json", "--wait"},
			wantErr: true,
		},
		"--wait snapshots once the extension registers": {
			history: booted, hiddenFor: 3, grace: 200 * time.Millisecond,
			args:    []string{"--once", "--plain", "--wait"},
			wantOut: "booted",
		},
		"--wait without a grace set waits the default": {
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
			env := runEnv{stdout: &out, stderr: io.Discard, poll: 5 * time.Millisecond, historyGrace: tc.grace}
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

// restartHistory is an old session's record, then a new session whose first
// record is trace.
var restartHistory = []map[string]any{
	{"v": 1, "seq": 5, "time": "2026-04-14T06:04:05Z", "level": "error", "severity": 500, "layer": "App", "message": "old session"},
	{"v": 1, "seq": 1, "time": "2026-04-14T06:05:00Z", "level": "trace", "severity": 0, "layer": "App", "message": "boot trace"},
	{"v": 1, "seq": 2, "time": "2026-04-14T06:05:01Z", "level": "error", "severity": 500, "layer": "App", "message": "new session error"},
}

func TestJSONStreamPrintsNoRestartDivider(t *testing.T) {
	srv := fakeVMServer(t, restartHistory, false)
	var out bytes.Buffer
	if err := (runEnv{stdout: &out, stderr: io.Discard}).run(t.Context(), []string{"--json", "-l", "info", srv}); err != nil {
		t.Fatalf("run --json -l info: %v", err)
	}
	lines := slices.Collect(strings.Lines(out.String()))
	for _, line := range lines {
		if _, err := record.Decode([]byte(line)); err != nil {
			t.Errorf("stdout line %q is not a record: %v", line, err)
		}
	}
	if len(lines) != 2 {
		t.Errorf("stdout has %d lines, want the 2 records:\n%s", len(lines), out.String())
	}
}

func TestReplayKeepsAnUnterminatedLastLineAndLongLines(t *testing.T) {
	line := func(msg string) string {
		return `{"v":1,"seq":1,"time":"2026-04-14T06:04:05Z","level":"info","severity":200,"layer":"App","message":"` + msg + `"}`
	}
	long := strings.Repeat("x", 70*1024)
	for name, tc := range map[string]struct{ in, want string }{
		"last line without a newline": {in: line("first") + "\n" + line("last"), want: "last"},
		"line over 64 KiB":            {in: line(long) + "\n", want: long},
	} {
		t.Run(name, func(t *testing.T) {
			var out bytes.Buffer
			env := runEnv{stdin: strings.NewReader(tc.in), stdout: &out, stderr: io.Discard}
			if err := env.run(t.Context(), []string{"--plain", "-"}); err != nil {
				t.Fatalf("replay: %v", err)
			}
			if !strings.Contains(out.String(), tc.want) {
				t.Errorf("stdout lacks the record (%d bytes):\n%.200s", out.Len(), out.String())
			}
		})
	}
}

func TestStdinReplayWithoutStdinIsEmpty(t *testing.T) {
	var out bytes.Buffer
	if err := (runEnv{stdout: &out}).run(t.Context(), []string{"--plain", "-"}); err != nil || out.Len() > 0 {
		t.Errorf("replay of an unset stdin = %v, %q; want nil, nothing", err, out.String())
	}
}

func TestMissingTargetWithoutWaitSuggestsWait(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing.vmservice")
	err := (runEnv{stdout: io.Discard, stderr: io.Discard}).run(t.Context(), []string{"--plain", missing})
	if err == nil || !strings.Contains(err.Error(), "pass --wait") {
		t.Errorf("run on a missing target = %v, want the --wait hint", err)
	}
}

func TestPlainStreamMarksRestartWhoseFirstRecordIsFiltered(t *testing.T) {
	srv := fakeVMServer(t, restartHistory, false)

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
	return serveVM(t, func(req vmReq) (map[string]any, vmEnd) {
		switch req.method {
		case "streamListen":
			return result(map[string]any{"type": "Success"}), vmKeep
		case "getVM":
			return result(mainVM), vmKeep
		case "getIsolate":
			if dropAt == req.method {
				return nil, vmDrop
			}
			return result(map[string]any{"extensionRPCs": []string{vmservice.HistoryExtension}}), vmKeep
		case vmservice.HistoryExtension:
			end := vmKeep
			if dropAt == req.method {
				end = vmDrop
			}
			return result(map[string]any{"records": []map[string]any{
				{"v": 1, "seq": 1, "time": "2026-04-14T06:04:05Z", "level": "info", "severity": 200, "layer": "App", "message": "one"},
			}}), end
		}
		return nil, vmKeep
	})
}

func TestPlainStreamOnDisconnect(t *testing.T) {
	for name, tc := range map[string]struct {
		dropAt     string
		noStderr   bool
		wantErr    error
		wantOut    string
		wantStderr string
	}{
		"target disconnect is a clean exit with a note":                 {dropAt: vmservice.HistoryExtension, wantOut: "one", wantStderr: "strata: target disconnected\n"},
		"drop before subscribing fails, run's error carries the report": {dropAt: "getIsolate", wantErr: vmservice.ErrClosed},
		"disconnect without stderr does not panic":                      {dropAt: vmservice.HistoryExtension, noStderr: true, wantOut: "one"},
	} {
		t.Run(name, func(t *testing.T) {
			srv := fakeVMServerDroppingAt(t, tc.dropAt)
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()

			var out, errOut bytes.Buffer
			env := runEnv{stdout: &out, stderr: &errOut}
			if tc.noStderr {
				env.stderr = nil
			}
			if err := env.run(ctx, []string{"--plain", srv}); !errors.Is(err, tc.wantErr) {
				t.Fatalf("run --plain dropped at %s = %v, want %v", tc.dropAt, err, tc.wantErr)
			}
			if !strings.Contains(out.String(), tc.wantOut) {
				t.Errorf("stdout = %q, want the record delivered before the drop", out.String())
			}
			if got := errOut.String(); got != tc.wantStderr {
				t.Errorf("stderr = %q, want %q", got, tc.wantStderr)
			}
		})
	}
}
