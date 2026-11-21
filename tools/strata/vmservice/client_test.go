package vmservice

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestPendingCallAnswersWhileRecordsGoUnread(t *testing.T) {
	const n = 5
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
			if req.Method == "getVM" {
				// The app logs while the client waits on its getVM reply.
				for seq := range int64(n) {
					send(map[string]any{"jsonrpc": "2.0", "method": "streamNotify", "params": map[string]any{
						"streamId": StreamID,
						"event": map[string]any{
							"extensionKind": EventKind,
							"isolate":       map[string]any{"id": "isolates/1", "name": "main"},
							"extensionData": wireRecordAt(seq+1, epoch, fmt.Sprintf("seq %d", seq+1)),
						},
					}})
				}
			}
			send(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": map[string]any{"type": "Success", "isolates": []any{}}})
		}
	}))
	t.Cleanup(srv.Close)

	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	c, err := Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http"))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if err := c.Listen(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := c.InspectVM(ctx); err != nil {
		t.Fatalf("InspectVM behind %d unread live records: %v", n, err)
	}
	for want := range int64(n) {
		select {
		case r := <-c.Records():
			if r.Seq != want+1 {
				t.Fatalf("record seq %d, want %d: live records out of order", r.Seq, want+1)
			}
		case <-ctx.Done():
			t.Fatalf("record %d of %d never delivered", want+1, n)
		}
	}
}
