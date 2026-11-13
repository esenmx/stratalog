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

	"github.com/esenmx/stratalog/tools/strata/internal/record"
)

var epoch = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

// rec is record seq of writer generation gen in isolate iso; each
// generation stamps distinct times.
func rec(iso string, gen int, seq int64) record.Record {
	return record.Record{
		V:         1,
		Seq:       seq,
		IsolateID: iso,
		Time:      epoch.Add(time.Duration(gen)*time.Hour + time.Duration(seq)*time.Second),
		Message:   fmt.Sprintf("%s/%d#%d", iso, gen, seq),
	}
}

func TestDedup(t *testing.T) {
	type step struct {
		live      bool
		r         record.Record
		keep      bool
		restarted bool
	}
	for name, steps := range map[string][]step{
		"first isolate is not a restart": {
			{live: true, r: rec("a", 0, 1), keep: true},
			{live: true, r: rec("a", 0, 2), keep: true},
		},
		"history drops records already seen live": {
			{live: true, r: rec("a", 0, 3), keep: true},
			{r: rec("a", 0, 2), keep: true},
			{r: rec("a", 0, 3)},
		},
		"live drops records already seen in history": {
			{r: rec("a", 0, 1), keep: true},
			{r: rec("a", 0, 2), keep: true},
			{live: true, r: rec("a", 0, 2)},
			{live: true, r: rec("a", 0, 3), keep: true},
		},
		"history repeated on reconnect is dropped": {
			{r: rec("a", 0, 1), keep: true},
			{r: rec("a", 0, 1)},
		},
		"seq going back live is a restart, record kept": {
			{live: true, r: rec("a", 0, 5), keep: true},
			{live: true, r: rec("a", 1, 1), keep: true, restarted: true},
			{live: true, r: rec("a", 1, 2), keep: true},
		},
		"seq repeating live with a new time is a restart": {
			{live: true, r: rec("a", 0, 1), keep: true},
			{live: true, r: rec("a", 1, 1), keep: true, restarted: true},
		},
		"restart resets history dedup": {
			{live: true, r: rec("a", 0, 2), keep: true},
			{live: true, r: rec("a", 1, 1), keep: true, restarted: true},
			{r: rec("a", 1, 1)},
			{r: rec("a", 1, 2), keep: true},
		},
		"history from a writer restarted while disconnected": {
			{live: true, r: rec("a", 0, 1), keep: true},
			{r: rec("a", 1, 1), keep: true, restarted: true},
			{live: true, r: rec("a", 1, 2), keep: true},
		},
		"history seq going back with newer times is a restart": {
			{r: rec("a", 0, 2001), keep: true},
			{r: rec("a", 0, 3000), keep: true},
			{r: rec("a", 1, 1), keep: true, restarted: true},
			{r: rec("a", 1, 2), keep: true},
			{live: true, r: rec("a", 1, 3), keep: true},
			{r: rec("a", 1, 1)},
		},
		"live seq going back with older times is not a restart": {
			{r: rec("a", 0, 5), keep: true},
			{live: true, r: rec("a", 0, 3), keep: true},
			{live: true, r: rec("a", 0, 5)},
		},
		"new isolate in history after another is a restart": {
			{live: true, r: rec("a", 0, 1), keep: true},
			{r: rec("b", 0, 1), keep: true, restarted: true},
			{r: rec("b", 0, 2), keep: true},
		},
		"new isolate live after another is a restart": {
			{live: true, r: rec("a", 0, 1), keep: true},
			{live: true, r: rec("b", 0, 1), keep: true, restarted: true},
		},
	} {
		t.Run(name, func(t *testing.T) {
			d := NewDedup()
			for i, s := range steps {
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

func wireRecord(seq int64) map[string]any {
	return map[string]any{
		"v":       1,
		"seq":     seq,
		"time":    epoch.Add(time.Duration(seq) * time.Second).Format(time.RFC3339Nano),
		"message": fmt.Sprintf("seq %d", seq),
	}
}

// fakeVM serves just enough VM service protocol for Stream: one isolate
// whose history response is withheld until two live events were sent, so
// live records arrive while history is in flight.
// fakeOpts shapes [fakeVM]'s one isolate. Live events are sent when the
// history call arrives, before its reply, so they are in flight together.
type fakeOpts struct {
	history, live []int64
	abrupt        bool // close right after the history reply
	hang          bool // never reply to the history call
}

// fakeVM serves just enough VM service protocol for Stream.
func fakeVM(t *testing.T, o fakeOpts) string {
	t.Helper()
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
		event := func(seq int64) {
			send(map[string]any{
				"jsonrpc": "2.0",
				"method":  "streamNotify",
				"params": map[string]any{
					"streamId": StreamID,
					"event": map[string]any{
						"kind":          "Extension",
						"extensionKind": EventKind,
						"isolate":       map[string]any{"id": "isolates/1"},
						"extensionData": wireRecord(seq),
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
			}
			_ = json.Unmarshal(b, &req)
			reply := func(result any) {
				send(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": result})
			}
			switch req.Method {
			case "streamListen":
				reply(map[string]any{"type": "Success"})
			case "getVM":
				reply(map[string]any{"isolates": []any{map[string]any{"id": "isolates/1"}}})
			case "getIsolate":
				reply(map[string]any{"extensionRPCs": []string{HistoryExtension}})
			case HistoryExtension:
				for _, seq := range o.live {
					event(seq)
				}
				if o.hang {
					continue
				}
				recs := make([]any, 0, len(o.history)+1)
				for _, seq := range o.history {
					recs = append(recs, wireRecord(seq))
				}
				recs = append(recs, map[string]any{"not": "a record"})
				reply(map[string]any{"records": recs})
				if !o.abrupt {
					// Let the client read everything, then drop the connection.
					time.Sleep(50 * time.Millisecond)
				}
				return
			}
		}
	}))
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http")
}

// label is an emitted item as "seq N", suffixed " (R)" when Restarted.
func label(it Item) string {
	if it.Restarted {
		return it.Rec.Message + " (R)"
	}
	return it.Rec.Message
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
		// More records than the ring between streamListen and the snapshot:
		// the oldest held ones were evicted from history.
		"burst overflows the ring": {
			opts: fakeOpts{history: []int64{3, 4, 5}, live: []int64{1, 2, 3, 4, 5}},
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
		d.Live(rec("a", 0, seq))
	}

	if got := len(d.isolates["a"].seen); got > 2*seenWindow+1 {
		t.Errorf("seen holds %d seqs, want at most %d", got, 2*seenWindow+1)
	}
	if keep, _ := d.History(rec("a", 0, n-seenWindow+1)); keep {
		t.Error("a repeat inside the window was kept")
	}
}
