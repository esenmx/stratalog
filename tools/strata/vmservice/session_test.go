package vmservice

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/esenmx/stratalog/tools/strata/record"
)

var epoch = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

func rec(iso, name string, gen int, seq int64) record.Record {
	return record.Record{
		V:           1,
		Seq:         seq,
		IsolateID:   iso,
		IsolateName: name,
		Time:        epoch.Add(time.Duration(gen)*time.Hour + time.Duration(seq)*time.Second),
		Message:     fmt.Sprintf("%s/%d#%d", iso, gen, seq),
	}
}

func TestDedup(t *testing.T) {
	type step struct {
		vmStart   int64 // optional ObserveVM before record
		live      bool
		r         record.Record
		keep      bool
		restarted bool
	}
	for name, steps := range map[string][]step{
		"first isolate is not a restart": {
			{live: true, r: rec("a", "main", 0, 1), keep: true},
			{live: true, r: rec("a", "main", 0, 2), keep: true},
		},
		"history drops records already seen live": {
			{live: true, r: rec("a", "main", 0, 3), keep: true},
			{r: rec("a", "main", 0, 2), keep: true},
			{r: rec("a", "main", 0, 3)},
		},
		"live drops records already seen in history": {
			{r: rec("a", "main", 0, 1), keep: true},
			{r: rec("a", "main", 0, 2), keep: true},
			{live: true, r: rec("a", "main", 0, 2)},
			{live: true, r: rec("a", "main", 0, 3), keep: true},
		},
		"history repeated on reconnect is dropped": {
			{vmStart: 100, r: rec("a", "main", 0, 1), keep: true},
			{vmStart: 100, r: rec("a", "main", 0, 1)},
		},
		"seq going back live is a restart, record kept": {
			{live: true, r: rec("a", "main", 0, 5), keep: true},
			{live: true, r: rec("a", "main", 1, 1), keep: true, restarted: true},
			{live: true, r: rec("a", "main", 1, 2), keep: true},
		},
		"seq repeating live with a new time is a restart": {
			{live: true, r: rec("a", "main", 0, 1), keep: true},
			{live: true, r: rec("a", "main", 1, 1), keep: true, restarted: true},
		},
		"restart resets history dedup": {
			{live: true, r: rec("a", "main", 0, 2), keep: true},
			{live: true, r: rec("a", "main", 1, 1), keep: true, restarted: true},
			{r: rec("a", "main", 1, 1)},
			{r: rec("a", "main", 1, 2), keep: true},
		},
		"history from a writer restarted while disconnected": {
			{live: true, r: rec("a", "main", 0, 1), keep: true},
			{r: rec("a", "main", 1, 1), keep: true, restarted: true},
			{live: true, r: rec("a", "main", 1, 2), keep: true},
		},
		"history seq going back with newer times is a restart": {
			{r: rec("a", "main", 0, 2001), keep: true},
			{r: rec("a", "main", 0, 3000), keep: true},
			{r: rec("a", "main", 1, 1), keep: true, restarted: true},
			{r: rec("a", "main", 1, 2), keep: true},
			{live: true, r: rec("a", "main", 1, 3), keep: true},
			{r: rec("a", "main", 1, 1)},
		},
		"live seq going back with older times is not a restart": {
			{r: rec("a", "main", 0, 5), keep: true},
			{live: true, r: rec("a", "main", 0, 3), keep: true},
			{live: true, r: rec("a", "main", 0, 5)},
		},
		"hot restart replacing main isolate is a restart": {
			{vmStart: 100, live: true, r: rec("a", "main", 0, 1), keep: true},
			{vmStart: 100, live: true, r: rec("b", "main", 0, 1), keep: true, restarted: true},
		},
		"relaunch with new VM startTime is a restart even with same isolate id": {
			{vmStart: 100, r: rec("a", "main", 0, 1), keep: true},
			{vmStart: 200, r: rec("a", "main", 1, 1), keep: true, restarted: true},
		},
		"worker isolate in same VM is NOT a restart": {
			{vmStart: 100, live: true, r: rec("a", "main", 0, 1), keep: true},
			{vmStart: 100, live: true, r: rec("w1", "drift", 0, 1), keep: true, restarted: false},
			{vmStart: 100, live: true, r: rec("w2", "Isolate.run", 0, 1), keep: true, restarted: false},
		},
	} {
		t.Run(name, func(t *testing.T) {
			d := NewDedup()
			for i, s := range steps {
				if s.vmStart != 0 {
					d.ObserveVM(VMInfo{StartTime: s.vmStart})
				}
				var keep, restarted bool
				if s.live {
					keep, restarted = d.Live(s.r)
				} else {
					keep, restarted = d.History(s.r)
				}
				if keep != s.keep || restarted != s.restarted {
					t.Errorf("step %d (live=%v %s) = keep %v restarted %v, want %v %v",
						i, s.live, s.r.Message, keep, restarted, s.keep, s.restarted)
				}
			}
		})
	}
}

func wireRecordAt(seq int64, at time.Time, msg string) map[string]any {
	return map[string]any{
		"v":       1,
		"seq":     seq,
		"time":    at.Format(time.RFC3339Nano),
		"message": msg,
	}
}

type fakeIsolate struct {
	id, name      string
	history, live []map[string]any
	hang          bool
}

type fakeOpts struct {
	startTime int64
	isolates  []fakeIsolate
	history   []int64
	live      []int64
	sameTick  bool // stamp all records with the exact same timestamp
	abrupt    bool // close right after the history reply (TCP reset)
	hang      bool // never reply to the history call
}

// fakeVM serves VM service JSON-RPC deterministically without time.Sleep.
func fakeVM(t *testing.T, o fakeOpts) string {
	t.Helper()
	isos := o.isolates
	if len(isos) == 0 {
		at := func(seq int64) time.Time {
			if o.sameTick {
				return epoch
			}
			return epoch.Add(time.Duration(seq) * time.Second)
		}
		var hist, live []map[string]any
		for _, seq := range o.history {
			hist = append(hist, wireRecordAt(seq, at(seq), fmt.Sprintf("seq %d", seq)))
		}
		for _, seq := range o.live {
			live = append(live, wireRecordAt(seq, at(seq), fmt.Sprintf("seq %d", seq)))
		}
		isos = []fakeIsolate{{id: "isolates/1", name: "main", history: hist, live: live, hang: o.hang}}
	}
	byID := map[string]fakeIsolate{}
	var vmStubs []any
	for _, iso := range isos {
		byID[iso.id] = iso
		vmStubs = append(vmStubs, map[string]any{"id": iso.id, "name": iso.name})
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer func() { _ = conn.CloseNow() }()
		ctx := r.Context()
		send := func(v any) {
			b, _ := json.Marshal(v)
			_ = conn.Write(ctx, websocket.MessageText, b)
		}
		event := func(iso fakeIsolate, rec map[string]any) {
			send(map[string]any{
				"jsonrpc": "2.0",
				"method":  "streamNotify",
				"params": map[string]any{
					"streamId": StreamID,
					"event": map[string]any{
						"kind":          "Extension",
						"extensionKind": EventKind,
						"isolate":       map[string]any{"id": iso.id, "name": iso.name},
						"extensionData": rec,
					},
				},
			})
		}
		histReplied := 0
		totalHist := len(isos)
		for {
			_, b, err := conn.Read(ctx)
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
			_ = json.Unmarshal(b, &req)
			reply := func(result any) {
				send(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": result})
			}
			switch req.Method {
			case "streamListen":
				reply(map[string]any{"type": "Success"})
			case "getVM":
				start := o.startTime
				if start == 0 {
					start = 1000
				}
				reply(map[string]any{"startTime": start, "isolates": vmStubs})
			case "getIsolate":
				iso := byID[req.Params.IsolateID]
				reply(map[string]any{"id": iso.id, "name": iso.name, "extensionRPCs": []string{HistoryExtension}})
			case HistoryExtension:
				iso := byID[req.Params.IsolateID]
				for _, rec := range iso.live {
					event(iso, rec)
				}
				if iso.hang {
					continue
				}
				recs := make([]any, 0, len(iso.history)+1)
				for _, rec := range iso.history {
					recs = append(recs, rec)
				}
				recs = append(recs, map[string]any{"not": "a record"})
				reply(map[string]any{"records": recs})
				histReplied++
				if histReplied == totalHist {
					if !o.abrupt {
						_ = conn.Close(websocket.StatusNormalClosure, "done")
					}
					return
				}
			}
		}
	}))
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http")
}

func label(it Item) string {
	s := it.Rec.Message
	if it.Rec.IsolateName != "" && it.Rec.IsolateName != "main" {
		s = "@" + it.Rec.IsolateName + ":" + s
	}
	if it.Restarted {
		return s + " (R)"
	}
	return s
}

func TestStreamOrdersHistoryAndLive(t *testing.T) {
	for name, tc := range map[string]struct {
		opts fakeOpts
		want []string
	}{
		"live after history": {
			opts: fakeOpts{history: []int64{1, 2, 3}, live: []int64{4, 5}},
			want: []string{"seq 1", "seq 2", "seq 3", "seq 4", "seq 5"},
		},
		"live overlaps history tail": {
			opts: fakeOpts{history: []int64{1, 2, 3}, live: []int64{3, 4}},
			want: []string{"seq 1", "seq 2", "seq 3", "seq 4"},
		},
		"history newer than a held live record": {
			opts: fakeOpts{history: []int64{1, 2, 3, 4}, live: []int64{3}},
			want: []string{"seq 1", "seq 2", "seq 3", "seq 4"},
		},
		"burst overflows the ring": {
			opts: fakeOpts{history: []int64{3, 4, 5}, live: []int64{1, 2, 3, 4, 5}},
			want: []string{"seq 1", "seq 2", "seq 3", "seq 4", "seq 5"},
		},
		"burst overflows the ring on the exact same clock tick": {
			opts: fakeOpts{history: []int64{3, 4, 5}, live: []int64{1, 2, 3, 4, 5}, sameTick: true},
			want: []string{"seq 1", "seq 2", "seq 3", "seq 4", "seq 5"},
		},
		"connection closes right after the history reply": {
			opts: fakeOpts{history: []int64{1, 2}, live: []int64{3}, abrupt: true},
			want: []string{"seq 1", "seq 2", "seq 3"},
		},
	} {
		t.Run(name, func(t *testing.T) {
			url := fakeVM(t, tc.opts)
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			c, err := Dial(ctx, url)
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()

			var got []string
			err = Stream(ctx, c, NewDedup(), func(it Item) { got = append(got, label(it)) })

			if err == nil || ctx.Err() != nil {
				t.Fatalf("Stream returned %v (ctx %v), want a connection-closed error", err, ctx.Err())
			}
			if !slices.Equal(got, tc.want) {
				t.Errorf("emitted %q, want %q", got, tc.want)
			}
			if got := c.Malformed(); got != 1 {
				t.Errorf("Malformed() = %d, want 1", got)
			}
		})
	}
}

func TestMultiIsolateChronologicalMergeWithoutFalseRestart(t *testing.T) {
	url := fakeVM(t, fakeOpts{
		isolates: []fakeIsolate{
			{
				id:   "isolates/1",
				name: "main",
				history: []map[string]any{
					wireRecordAt(1, epoch.Add(1*time.Second), "m1"),
					wireRecordAt(2, epoch.Add(3*time.Second), "m2"),
				},
			},
			{
				id:   "isolates/2",
				name: "drift",
				history: []map[string]any{
					wireRecordAt(1, epoch.Add(2*time.Second), "d1"),
					wireRecordAt(2, epoch.Add(4*time.Second), "d2"),
				},
			},
		},
	})
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	c, err := Dial(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	var got []string
	_ = Stream(ctx, c, NewDedup(), func(it Item) { got = append(got, label(it)) })

	want := []string{"m1", "@drift:d1", "m2", "@drift:d2"}
	if !slices.Equal(got, want) {
		t.Errorf("multi-isolate Stream = %q, want %q", got, want)
	}
}

func TestSnapshotFetchesMergedHistoryOnce(t *testing.T) {
	url := fakeVM(t, fakeOpts{
		isolates: []fakeIsolate{
			{
				id:      "isolates/1",
				name:    "main",
				history: []map[string]any{wireRecordAt(1, epoch.Add(2*time.Second), "m1")},
			},
			{
				id:      "isolates/2",
				name:    "drift",
				history: []map[string]any{wireRecordAt(1, epoch.Add(1*time.Second), "d1")},
			},
		},
	})
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	c, err := Dial(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	items, err := Snapshot(ctx, c)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, it := range items {
		got = append(got, label(it))
	}
	if want := []string{"@drift:d1", "m1"}; !slices.Equal(got, want) {
		t.Errorf("Snapshot = %q, want %q", got, want)
	}
}

func TestStreamReleasesLiveWhenHistoryHangs(t *testing.T) {
	defer func(d time.Duration) { historyTimeout = d }(historyTimeout)
	historyTimeout = 100 * time.Millisecond

	url := fakeVM(t, fakeOpts{live: []int64{1, 2, 3}, hang: true})
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	c, err := Dial(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	var got []string
	_ = Stream(ctx, c, NewDedup(), func(it Item) {
		if got = append(got, label(it)); len(got) == 3 {
			cancel()
		}
	})

	if want := []string{"seq 1", "seq 2", "seq 3"}; !slices.Equal(got, want) {
		t.Errorf("emitted %q, want %q", got, want)
	}
}

func TestDedupPrunesBeyondWindowOnly(t *testing.T) {
	d := NewDedup()
	const n = 3*seenWindow + 1
	for seq := int64(1); seq <= n; seq++ {
		d.Live(rec("a", "main", 0, seq))
	}

	if got := len(d.isolates["a"].seen); got > 2*seenWindow+1 {
		t.Errorf("seen holds %d seqs, want at most %d", got, 2*seenWindow+1)
	}
	if keep, _ := d.History(rec("a", "main", 0, n-seenWindow+1)); keep {
		t.Error("a repeat inside the window was kept")
	}
}

func TestPausedWorkerIsolateDoesNotStallMainLive(t *testing.T) {
	// historyTimeout stays at its 5 s default; if main were blocked by the
	// hanging late worker isolate, this 500 ms context would time out!
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer func() { _ = conn.CloseNow() }()
		ctx := r.Context()
		send := func(v any) {
			b, _ := json.Marshal(v)
			_ = conn.Write(ctx, websocket.MessageText, b)
		}
		event := func(isoID, isoName string, seq int64, msg string) {
			send(map[string]any{
				"jsonrpc": "2.0",
				"method":  "streamNotify",
				"params": map[string]any{
					"streamId": StreamID,
					"event": map[string]any{
						"kind":          "Extension",
						"extensionKind": EventKind,
						"isolate":       map[string]any{"id": isoID, "name": isoName},
						"extensionData": wireRecordAt(seq, epoch.Add(time.Duration(seq)*time.Second), msg),
					},
				},
			})
		}
		for {
			_, b, err := conn.Read(ctx)
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
			_ = json.Unmarshal(b, &req)
			reply := func(result any) {
				send(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": result})
			}
			switch req.Method {
			case "streamListen":
				reply(map[string]any{"type": "Success"})
			case "getVM":
				reply(map[string]any{"startTime": 1000, "isolates": []any{map[string]any{"id": "isolates/1", "name": "main"}}})
			case "getIsolate":
				reply(map[string]any{"id": "isolates/1", "name": "main", "extensionRPCs": []string{HistoryExtension}})
			case HistoryExtension:
				if req.Params.IsolateID == "isolates/1" {
					reply(map[string]any{"records": []any{wireRecordAt(1, epoch, "boot")}})
					// Now spawn a worker isolate whose history hangs, followed
					// immediately by a live event on main!
					event("isolates/99", "worker", 1, "worker-1")
					event("isolates/1", "main", 2, "main-live-2")
				}
				// isolates/99 never replies (paused isolate).
			}
		}
	}))
	t.Cleanup(srv.Close)

	ctx, cancel := context.WithTimeout(t.Context(), 500*time.Millisecond)
	defer cancel()
	c, err := Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http"))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	var got []string
	_ = Stream(ctx, c, NewDedup(), func(it Item) {
		got = append(got, label(it))
		if it.Rec.Message == "main-live-2" {
			cancel()
		}
	})

	if want := []string{"boot", "main-live-2"}; !slices.Equal(got, want) {
		t.Fatalf("emitted %q, want %q without stalling on paused worker", got, want)
	}
}

func TestSnapshotReportsIsolatesWhoseHistoryFailed(t *testing.T) {
	defer func(d time.Duration) { historyTimeout = d }(historyTimeout)
	historyTimeout = 100 * time.Millisecond

	url := fakeVM(t, fakeOpts{
		isolates: []fakeIsolate{
			{
				id:      "isolates/1",
				name:    "main",
				history: []map[string]any{wireRecordAt(1, epoch, "m1")},
			},
			// Paused at a breakpoint: the extension never replies.
			{id: "isolates/2", name: "drift", hang: true},
		},
	})
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	c, err := Dial(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	items, err := Snapshot(ctx, c)
	if err == nil || !strings.Contains(err.Error(), "drift") {
		t.Errorf("Snapshot err = %v, want one naming the failed drift isolate", err)
	}
	var got []string
	for _, it := range items {
		got = append(got, label(it))
	}
	if want := []string{"m1"}; !slices.Equal(got, want) {
		t.Errorf("Snapshot items = %q, want the reachable isolate's %q", got, want)
	}
}
