package ui

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"github.com/esenmx/stratalog/tools/strata/internal/record"
	"github.com/esenmx/stratalog/tools/strata/internal/vmservice"
)

var at = time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)

func appBoot() record.Record {
	return record.Record{V: 1, Seq: 1, Time: at, Level: "info", Severity: 200, Layer: "App", Color: "#5fafff", OnColor: "#000000", Message: "demo boot"}
}

func network() record.Record {
	return record.Record{
		V: 1, Seq: 2, Time: at, Level: "info", Severity: 200, Layer: "Network", Color: "#875fff", OnColor: "#ffffff",
		Message: "← 200 GET https://api.example.com/users/42",
		Data:    json.RawMessage(`{"status":200,"body":{"id":42,"name":"Jane","tags":["a","b"]}}`),
	}
}

func stateTrace() record.Record {
	return record.Record{V: 1, Seq: 3, Time: at, Level: "trace", Severity: 0, Layer: "State", Message: "demo state", Data: json.RawMessage(`{"cart":{"items":3}}`)}
}

// newModel is a sized model holding recs, following as on startup.
func newModel(t *testing.T, recs ...record.Record) *Model {
	t.Helper()
	m := New("./.flutter.vmservice")
	send(m, tea.WindowSizeMsg{Width: 120, Height: 20})
	for _, r := range recs {
		send(m, RecordMsg(vmservice.Item{Rec: r}, 0))
	}
	return m
}

func send(m *Model, msgs ...tea.Msg) tea.Cmd {
	var cmd tea.Cmd
	for _, msg := range msgs {
		_, cmd = m.Update(msg)
	}
	return cmd
}

// key builds the press for a key name as KeyPressMsg.String() reports it.
func key(name string) tea.KeyPressMsg {
	switch name {
	case "enter":
		return tea.KeyPressMsg{Code: tea.KeyEnter}
	case "esc":
		return tea.KeyPressMsg{Code: tea.KeyEscape}
	case "up":
		return tea.KeyPressMsg{Code: tea.KeyUp}
	case "down":
		return tea.KeyPressMsg{Code: tea.KeyDown}
	case "left":
		return tea.KeyPressMsg{Code: tea.KeyLeft}
	case "space":
		return tea.KeyPressMsg{Code: tea.KeySpace, Text: " "}
	}
	r := []rune(name)[0]
	return tea.KeyPressMsg{Code: r, Text: name}
}

func keys(names ...string) []tea.Msg {
	msgs := make([]tea.Msg, 0, len(names))
	for _, n := range names {
		msgs = append(msgs, key(n))
	}
	return msgs
}

func typed(s string) []tea.Msg {
	msgs := make([]tea.Msg, 0, len(s))
	for _, r := range s {
		msgs = append(msgs, key(string(r)))
	}
	return msgs
}

func screen(m *Model) string { return ansi.Strip(m.View().Content) }

func TestEnterOpensRecordIntoTree(t *testing.T) {
	m := newModel(t, appBoot(), network())
	if strings.Contains(screen(m), "body") {
		t.Fatal(`"body" shown before opening`)
	}

	send(m, key("enter"))

	s := screen(m)
	if !strings.Contains(s, "body: {…} 3 keys") {
		t.Errorf("opened record lacks a closed body row:\n%s", s)
	}
	if strings.Contains(s, "Jane") {
		t.Errorf("nested body opened too:\n%s", s)
	}

	send(m, keys("down", "down", "enter")...) // status, body → open body
	if s := screen(m); !strings.Contains(s, `name: "Jane"`) {
		t.Errorf("opening body did not show its keys:\n%s", s)
	}
}

func TestFilterKeepsMatchingRecords(t *testing.T) {
	m := newModel(t, appBoot(), network(), stateTrace())

	send(m, key("/"))
	send(m, typed("Jane")...)
	send(m, key("enter"))

	s := screen(m)
	if !strings.Contains(s, "GET https://api.example.com/users/42") {
		t.Errorf("Network record filtered out:\n%s", s)
	}
	for _, gone := range []string{"demo boot", "demo state"} {
		if strings.Contains(s, gone) {
			t.Errorf("%q survives filter Jane:\n%s", gone, s)
		}
	}
	if len(m.rows) != 1 {
		t.Errorf("rows = %d, want 1", len(m.rows))
	}

	send(m, key("esc"))
	if len(m.rows) != 3 {
		t.Errorf("rows after esc = %d, want 3", len(m.rows))
	}
}

func TestFilterInputSwallowsCommandKeys(t *testing.T) {
	m := newModel(t, appBoot(), network())

	send(m, key("/"))
	cmd := send(m, typed("qce")...)

	if m.filter.Value() != "qce" {
		t.Errorf("filter = %q, want %q", m.filter.Value(), "qce")
	}
	if m.records != 2 {
		t.Errorf("records = %d after typing c, want 2 (not cleared)", m.records)
	}
	if cmd != nil {
		if _, quit := cmd().(tea.QuitMsg); quit {
			t.Error("typing q in the filter quit")
		}
	}
}

func TestFollowTracksNewRecords(t *testing.T) {
	m := newModel(t, appBoot(), network())
	if !m.follow {
		t.Fatal("not following on startup")
	}

	send(m, key("up"))
	if m.follow {
		t.Error("up kept follow")
	}

	send(m, key("G"))
	if !m.follow {
		t.Error("G did not set follow")
	}
	send(m, RecordMsg(vmservice.Item{Rec: stateTrace()}, 0))
	if last := len(m.rows) - 1; m.cursor != last {
		t.Errorf("cursor = %d after a new record, want last row %d", m.cursor, last)
	}
	if s := screen(m); !strings.Contains(s, "❯ ▸  State ") {
		t.Errorf("cursor not drawn on the new record:\n%s", s)
	}
}

func TestUpStopsFollowAndKeepsPosition(t *testing.T) {
	m := newModel(t, appBoot(), network())
	send(m, key("up"))
	at := m.cursor

	send(m, RecordMsg(vmservice.Item{Rec: stateTrace()}, 0))

	if m.follow || m.cursor != at {
		t.Errorf("follow = %v, cursor = %d; want false, %d", m.follow, m.cursor, at)
	}
}

func TestLevelCycleHidesTrace(t *testing.T) {
	m := newModel(t, appBoot(), stateTrace())
	if !strings.Contains(screen(m), "demo state") {
		t.Fatal("trace record hidden at the default level")
	}

	send(m, key("L"))

	s := screen(m)
	if strings.Contains(s, "demo state") {
		t.Errorf("trace record shown at ≥debug:\n%s", s)
	}
	if !strings.Contains(s, "≥debug") {
		t.Errorf("status lacks the level:\n%s", s)
	}
}

func TestLeftClosesThenJumpsToParent(t *testing.T) {
	m := newModel(t, network())
	send(m, keys("enter", "down", "down", "enter", "down")...) // on body.id

	if r, _ := m.current(); r.kind != rowNode || r.node.Key != "id" {
		t.Fatalf("cursor on %+v, want body.id", r)
	}
	send(m, key("left"))
	if r, _ := m.current(); r.node == nil || r.node.Key != "body" {
		t.Fatalf("left from id landed on %+v, want body", r)
	}
	send(m, key("left")) // closes body
	if strings.Contains(screen(m), "Jane") {
		t.Error("left on open body did not close it")
	}
	send(m, keys("left", "left")...) // body → header, header closes
	if r, _ := m.current(); r.kind != rowHeader || r.entry.Open {
		t.Errorf("cursor on %+v, want the closed header", r)
	}
}

func TestExpandAllThenCollapse(t *testing.T) {
	m := newModel(t, network())

	send(m, key("e"))
	if s := screen(m); !strings.Contains(s, `1: "b"`) {
		t.Errorf("e did not open every node:\n%s", s)
	}

	send(m, key("e"))
	if len(m.rows) != 1 || m.cursor != 0 {
		t.Errorf("second e left %d rows, cursor %d; want 1, 0", len(m.rows), m.cursor)
	}
}

func TestRestartInsertsDivider(t *testing.T) {
	m := newModel(t, appBoot())
	r := appBoot()
	r.Message = "after restart"

	send(m, RecordMsg(vmservice.Item{Rec: r, Restarted: true}, 0))

	s := screen(m)
	if !strings.Contains(s, "── session restarted") {
		t.Errorf("no divider:\n%s", s)
	}
	if !strings.Contains(s, "after restart") || m.records != 2 {
		t.Errorf("restarted record missing (records = %d):\n%s", m.records, s)
	}
}

func TestReconnectKeepsRecordsAndDividesOnlyOnRestart(t *testing.T) {
	m := newModel(t)
	send(m, ConnMsg(Connected, "ws://a/ws", 0), RecordMsg(vmservice.Item{Rec: appBoot()}, 0))
	send(m, ConnMsg(Disconnected, "connection lost", 0))
	if s := screen(m); !strings.Contains(s, "disconnected: connection lost") || !strings.Contains(s, "demo boot") {
		t.Errorf("disconnect lost records or state:\n%s", s)
	}

	send(m, ConnMsg(Connected, "ws://a/ws", 2))
	if s := screen(m); strings.Contains(s, restartedLabel) || !strings.Contains(s, "malformed 2") {
		t.Errorf("same-app reconnect drew a divider or lost the malformed count:\n%s", s)
	}

	relaunched := appBoot()
	relaunched.IsolateID = "isolates/2"
	send(m, RecordMsg(vmservice.Item{Rec: relaunched, Restarted: true}, 2))
	if n := strings.Count(screen(m), restartedLabel); n != 1 {
		t.Errorf("relaunch drew %d dividers, want 1:\n%s", n, screen(m))
	}
}

func TestCapDropsOldestAndKeepsCursorOnItsRecord(t *testing.T) {
	m := newModel(t)
	add := func(i int) {
		r := appBoot()
		r.Seq = int64(i + 1)
		r.Message = fmt.Sprintf("r%d", i)
		send(m, RecordMsg(vmservice.Item{Rec: r}, 0))
	}
	for i := range MaxEntries {
		add(i)
	}
	send(m, key("g"))
	for range 100 {
		send(m, key("down"))
	}

	for i := range 5 {
		add(MaxEntries + i)
	}

	if len(m.entries) != MaxEntries || m.dropped != 5 {
		t.Errorf("entries = %d, dropped = %d; want %d, 5", len(m.entries), m.dropped, MaxEntries)
	}
	if r, ok := m.current(); !ok || r.entry.Rec.Message != "r100" {
		t.Errorf("cursor moved off r100 to %+v", r)
	}
	if s := screen(m); !strings.Contains(s, "dropped 5") {
		t.Errorf("status lacks the dropped count:\n%s", s)
	}
}

func TestNewerSchemaWarnsOnce(t *testing.T) {
	r := appBoot()
	r.V = 2
	m := newModel(t, r, r)

	if s := screen(m); strings.Count(s, "schema v2") != 1 {
		t.Errorf("want one schema warning:\n%s", s)
	}
}

func TestResizeClampsCursor(t *testing.T) {
	m := newModel(t, appBoot(), network(), stateTrace())
	send(m, tea.WindowSizeMsg{Width: 40, Height: 3})

	if m.cursor < m.offset || m.cursor >= m.offset+m.bodyHeight() {
		t.Errorf("cursor %d outside view [%d, %d)", m.cursor, m.offset, m.offset+m.bodyHeight())
	}
	for line := range strings.SplitSeq(screen(m), "\n") {
		if w := ansi.StringWidth(line); w > 40 {
			t.Errorf("line %q is %d cells, want ≤ 40", line, w)
		}
	}
}

func TestWaitingStateBeforeAnyRecord(t *testing.T) {
	m := newModel(t)
	if s := screen(m); !strings.Contains(s, "waiting for ./.flutter.vmservice") {
		t.Errorf("no waiting state:\n%s", s)
	}
}
