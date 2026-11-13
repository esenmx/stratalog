package vmservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"sync"
	"sync/atomic"

	"github.com/coder/websocket"
	"github.com/samber/lo"

	"github.com/esenmx/stratalog/tools/strata/internal/record"
)

// VM service names stratalog's VmStreamWriter posts to and serves.
const (
	StreamID         = "stratalog"
	EventKind        = "stratalog.record"
	HistoryExtension = "ext.stratalog.history"
)

// ErrClosed reports a call on, or a stream from, a closed connection.
var ErrClosed = errors.New("vmservice: connection closed")

// Client is one VM service connection. One reader goroutine routes
// responses to pending calls and stratalog events to [Client.Records].
//
// The reader never blocks on a slow consumer: live records queue unbounded
// between it and [Client.Records], so a pending call's response can always
// arrive.
type Client struct {
	conn    *websocket.Conn
	live    chan record.Record // reader → pump
	records chan record.Record // pump → consumer
	done    chan struct{}      // closed when the reader exits
	quit    chan struct{}      // closed by Close

	nextID    atomic.Int64
	malformed atomic.Int64

	mu        sync.Mutex
	pending   map[string]chan response
	err       error // why the reader exited
	closeOnce sync.Once
}

type response struct {
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
}

type rpcError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

func (e *rpcError) Error() string {
	return fmt.Sprintf("vmservice: %s (code %d)", e.Message, e.Code)
}

// Dial connects to the VM service WebSocket at wsURL.
func Dial(ctx context.Context, wsURL string) (*Client, error) {
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		return nil, fmt.Errorf("vmservice: dial %s: %w", wsURL, err)
	}
	// History responses carry up to 1000 full payloads.
	conn.SetReadLimit(-1)
	c := &Client{
		conn:    conn,
		live:    make(chan record.Record),
		records: make(chan record.Record),
		done:    make(chan struct{}),
		quit:    make(chan struct{}),
		pending: map[string]chan response{},
	}
	go c.read()
	go c.pump()
	return c, nil
}

// Close drops the connection and any undelivered records, then closes
// [Client.Records].
func (c *Client) Close() {
	c.closeOnce.Do(func() { close(c.quit) })
	_ = c.conn.CloseNow()
	<-c.done
}

// pump forwards live records in order through an unbounded queue. After the
// reader exits it drains the queue, then closes records.
func (c *Client) pump() {
	defer close(c.records)
	var queue []record.Record
	in := c.live
	for in != nil || len(queue) > 0 {
		var out chan record.Record
		var head record.Record
		if len(queue) > 0 {
			out, head = c.records, queue[0]
		}
		select {
		case r, ok := <-in:
			if !ok {
				in = nil
				continue
			}
			queue = append(queue, r)
		case out <- head:
			queue = queue[1:]
		case <-c.quit:
			return
		}
	}
}

// Records delivers live records posted on the stratalog stream after
// [Client.Listen]. It closes once the connection drops and every record
// received before the drop was delivered.
func (c *Client) Records() <-chan record.Record { return c.records }

// Malformed counts stream events and history entries skipped because they
// did not decode as records.
func (c *Client) Malformed() int64 { return c.malformed.Load() }

// Err is why the connection ended; nil while it is open.
func (c *Client) Err() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.err
}

// Call sends one JSON-RPC request and waits for its result.
func (c *Client) Call(ctx context.Context, method string, params any) (json.RawMessage, error) {
	id := strconv.FormatInt(c.nextID.Add(1), 10)
	ch := make(chan response, 1)
	c.mu.Lock()
	if c.err != nil {
		c.mu.Unlock()
		return nil, c.err
	}
	c.pending[id] = ch
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
	}()

	req, err := json.Marshal(struct {
		JSONRPC string `json:"jsonrpc"`
		ID      string `json:"id"`
		Method  string `json:"method"`
		Params  any    `json:"params,omitempty"`
	}{"2.0", id, method, params})
	if err != nil {
		return nil, err
	}
	if err := c.conn.Write(ctx, websocket.MessageText, req); err != nil {
		return nil, fmt.Errorf("vmservice: %s: %w", method, err)
	}
	select {
	case resp := <-ch:
		if resp.Error != nil {
			return nil, fmt.Errorf("%s: %w", method, resp.Error)
		}
		return resp.Result, nil
	case <-c.done:
		// The reply may have landed just before the drop.
		select {
		case resp := <-ch:
			if resp.Error != nil {
				return nil, fmt.Errorf("%s: %w", method, resp.Error)
			}
			return resp.Result, nil
		default:
			return nil, c.Err()
		}
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// Listen subscribes to the stratalog stream.
func (c *Client) Listen(ctx context.Context) error {
	_, err := c.Call(ctx, "streamListen", map[string]string{"streamId": StreamID})
	return err
}

// HistoryIsolates lists every isolate that registered [HistoryExtension].
func (c *Client) HistoryIsolates(ctx context.Context) ([]string, error) {
	raw, err := c.Call(ctx, "getVM", nil)
	if err != nil {
		return nil, err
	}
	var vm struct {
		Isolates []struct {
			ID string `json:"id"`
		} `json:"isolates"`
	}
	if err := json.Unmarshal(raw, &vm); err != nil {
		return nil, fmt.Errorf("getVM: %w", err)
	}
	var ids []string
	for _, iso := range vm.Isolates {
		raw, err := c.Call(ctx, "getIsolate", map[string]string{"isolateId": iso.ID})
		if err != nil {
			continue // exited between getVM and getIsolate
		}
		var info struct {
			ExtensionRPCs []string `json:"extensionRPCs"`
		}
		if json.Unmarshal(raw, &info) == nil && slices.Contains(info.ExtensionRPCs, HistoryExtension) {
			ids = append(ids, iso.ID)
		}
	}
	return ids, nil
}

// FindHistoryIsolate returns the first isolate serving [HistoryExtension].
func (c *Client) FindHistoryIsolate(ctx context.Context) (string, bool, error) {
	ids, err := c.HistoryIsolates(ctx)
	if err != nil || len(ids) == 0 {
		return "", false, err
	}
	return ids[0], true, nil
}

// History fetches the isolate's buffered records, oldest first.
func (c *Client) History(ctx context.Context, isolateID string) ([]record.Record, error) {
	raw, err := c.Call(ctx, HistoryExtension, map[string]string{"isolateId": isolateID})
	if err != nil {
		return nil, err
	}
	var hist struct {
		Records []json.RawMessage `json:"records"`
	}
	if err := json.Unmarshal(raw, &hist); err != nil {
		return nil, fmt.Errorf("%s: %w", HistoryExtension, err)
	}
	return lo.FilterMap(hist.Records, func(b json.RawMessage, _ int) (record.Record, bool) {
		r, err := record.Decode(b)
		if err != nil {
			c.malformed.Add(1)
			return record.Record{}, false
		}
		r.IsolateID = isolateID
		return r, true
	}), nil
}

// envelope is any inbound message: a response (ID set) or a notification.
type envelope struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params struct {
		StreamID string `json:"streamId"`
		Event    struct {
			ExtensionKind string `json:"extensionKind"`
			Isolate       struct {
				ID string `json:"id"`
			} `json:"isolate"`
			ExtensionData json.RawMessage `json:"extensionData"`
		} `json:"event"`
	} `json:"params"`
	response
}

func (c *Client) read() {
	defer close(c.done)
	defer close(c.live)
	ctx := context.Background()
	for {
		_, b, err := c.conn.Read(ctx)
		if err != nil {
			c.mu.Lock()
			c.err = fmt.Errorf("%w: %w", ErrClosed, err)
			c.mu.Unlock()
			return
		}
		var env envelope
		if err := json.Unmarshal(b, &env); err != nil {
			continue
		}
		switch {
		case len(env.ID) > 0:
			c.deliver(env)
		case env.Method == "streamNotify" &&
			env.Params.StreamID == StreamID &&
			env.Params.Event.ExtensionKind == EventKind:
			r, err := record.Decode(env.Params.Event.ExtensionData)
			if err != nil {
				c.malformed.Add(1)
				continue
			}
			r.IsolateID = env.Params.Event.Isolate.ID
			select {
			case c.live <- r:
			case <-c.quit:
			}
		}
	}
}

func (c *Client) deliver(env envelope) {
	var id string
	if json.Unmarshal(env.ID, &id) != nil {
		id = string(env.ID) // numeric id from a peer; ours are strings
	}
	c.mu.Lock()
	ch, ok := c.pending[id]
	c.mu.Unlock()
	if ok {
		ch <- env.response
	}
}
