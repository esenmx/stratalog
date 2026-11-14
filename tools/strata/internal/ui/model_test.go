package ui

import (
	"encoding/json"
	"fmt"
	"math"
	"strconv"
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
	return record.Record{
		V: 1, Seq: 1, Time: at, Level: "info", Severity: 200, Layer: "App",
		Color: "#0087af", OnColor: "#ffffff",
		File: "strata_demo", Line: 13, Method: "main",
		Message: "demo boot",
	}
}

func network() record.Record {
	return record.Record{
		V: 1, Seq: 2, Time: at, Level: "info", Severity: 200, Layer: "Network",
		Color: "#875fff", OnColor: "#ffffff",
		File: "api_client", Line: 87, Method: "fetchUser",
		Message: "← 200 GET https://api.example.com/users/42",
		Data:    json.RawMessage(`{"status":200,"body":{"id":42,"name":"Jane","tags":["a","b"]}}`),
	}
}

func stateTrace() record.Record {
	return record.Record{
		V: 1, Seq: 3, Time: at, Level: "trace", Severity: 0, Layer: "State",
		File: "cart_notifier", Line: 21,
		Message: "demo state",
		Data:    json.RawMessage(`{"cart":{"items":3}}`),
	}
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
	case "right":
		return tea.KeyPressMsg{Code: tea.KeyRight}
	case "pgup":
		return tea.KeyPressMsg{Code: tea.KeyPgUp}
	case "pgdown":
		return tea.KeyPressMsg{Code: tea.KeyPgDown}
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

func TestBareCallerRecordShowsNoFakeDisclosureTriangle(t *testing.T) {
	m := newModel(t, appBoot(), network())
	s := screen(m)
	// appBoot has File/Line/Method as every real record does, without Data/Error/Stack:
	// it must NOT render a fake ▸ triangle, while network() with Data MUST render ▸ and its vital preview.
	if strings.Contains(s, "▸  App ") {
		t.Errorf("bare one-line record with caller info rendered fake ▸:\n%s", s)
	}
	if !strings.Contains(s, "▸  Network ") || !strings.Contains(s, "status: 200") {
		t.Errorf("Network record missing ▸ or vital preview:\n%s", s)
	}
}

func TestEnterOpensRecordIntoTree(t *testing.T) {
	m := newModel(t, appBoot(), network())
	if strings.Contains(screen(m), "body:") {
		t.Fatal(`"body:" shown before opening`)
	}

	send(m, key("enter"))

	s := screen(m)
	if !strings.Contains(s, "body: {…} 3 keys") {
		t.Errorf("opened record lacks a closed body row:\n%s", s)
	}
	if strings.Contains(s, `"Jane"`) {
		t.Errorf("nested body opened too:\n%s", s)
	}

	send(m, keys("down", "down", "down", "enter")...) // caller, status, body → open body
	if s := screen(m); !strings.Contains(s, `name: "Jane"`) {
		t.Errorf("opening body did not show its keys:\n%s", s)
	}
}

func TestMultiLineStringInDataFoldsIntoLines(t *testing.T) {
	r := appBoot()
	r.Layer = "Storage"
	r.Data = json.RawMessage(`{"sql":"SELECT *\nFROM users\nWHERE id = 42"}`)
	m := newModel(t, r)

	send(m, key("e"))
	s := screen(m)
	if !strings.Contains(s, "FROM users") || !strings.Contains(s, "WHERE id = 42") {
		t.Errorf("multi-line JSON string did not unfold into lines:\n%s", s)
	}
}

func TestWrapAndYankUnelidedValues(t *testing.T) {
	long := "https://api.example.com/v1/organizations/org_999/projects/proj_888/deployments/dep_777/logs?cursor=abcdef1234567890"
	r := network()
	r.Data = json.RawMessage(fmt.Sprintf(`{"url":%q}`, long))
	m := newModel(t)
	send(m, tea.WindowSizeMsg{Width: 60, Height: 20})
	send(m, RecordMsg(vmservice.Item{Rec: r}, 0))
	send(m, key("e"))

	if strings.Contains(screen(m), "cursor=abcdef1234567890") {
		t.Fatal("expected long URL to truncate before wrap toggle")
	}

	send(m, key("w"))
	if s := screen(m); !strings.Contains(strings.ReplaceAll(s, "\n", ""), "cursor=abcdef1234567890") {
		t.Errorf("wrap toggle did not reveal full URL:\n%s", s)
	}

	// Move cursor onto url node (header -> caller -> url) and yank with y.
	send(m, keys("g", "down", "down")...)
	cmd := send(m, key("y"))
	if cmd == nil {
		t.Fatal("y on scalar node returned nil Cmd, want SetClipboard")
	}
	if s := screen(m); !strings.Contains(s, "copied") {
		t.Errorf("status bar missing copied notice:\n%s", s)
	}
}

func TestFilterEscAnchorsCursorOnSelectedRecord(t *testing.T) {
	r1 := appBoot()
	r1.Message = "boot 1"
	r2 := network()
	r3 := stateTrace()
	m := newModel(t, r1, r2, r3)

	send(m, key("/"))
	send(m, typed("Jane")...)
	send(m, key("enter"))

	if len(m.rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(m.rows))
	}

	// Clearing filter with Esc must keep cursor anchored on network() (row 1),
	// NOT jump to row 0 (boot 1).
	send(m, key("esc"))
	if len(m.rows) != 3 {
		t.Fatalf("rows after esc = %d, want 3", len(m.rows))
	}
	if cur, ok := m.current(); !ok || cur.entry.Rec.Layer != "Network" {
		t.Errorf("cursor after Esc landed on %+v, want Network record", cur)
	}
}

func TestFilterOrphanedDividersHiddenWhenZeroRecordsMatch(t *testing.T) {
	m := newModel(t, appBoot())
	r := appBoot()
	r.Seq = 1
	r.Message = "after restart"
	send(m, RecordMsg(vmservice.Item{Rec: r, Restarted: true}, 0))

	send(m, key("/"))
	send(m, typed("nonexistent")...)
	send(m, key("enter"))

	s := screen(m)
	if strings.Contains(s, restartedLabel) || !strings.Contains(s, "no records match") {
		t.Errorf("zero-match filter showed orphaned divider instead of 'no records match':\n%s", s)
	}
}

func TestLayerFilterTogglesLayers(t *testing.T) {
	m := newModel(t, appBoot(), network(), stateTrace())

	// Open layer bar with 'f', toggle index 2 ("Network": App=1, Network=2, State=3), close.
	send(m, keys("f", "2", "enter")...)
	s := screen(m)
	if !strings.Contains(s, "GET https://api.example.com/users/42") {
		t.Errorf("Network hidden when selected:\n%s", s)
	}
	if strings.Contains(s, "demo boot") || strings.Contains(s, "demo state") {
		t.Errorf("unselected layers still visible:\n%s", s)
	}

	// 'F' clears layer filter.
	send(m, key("F"))
	if len(m.rows) != 3 {
		t.Errorf("rows after F = %d, want 3", len(m.rows))
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

func TestFollowTracksNewRecordsAndClearRestoresFollow(t *testing.T) {
	m := newModel(t, appBoot(), network())
	if !m.follow {
		t.Fatal("not following on startup")
	}

	send(m, key("up"))
	if m.follow {
		t.Error("up kept follow")
	}

	// Right arrow on non-openable appBoot must NOT break follow once re-enabled.
	m2 := newModel(t, appBoot())
	send(m2, key("right"))
	if !m2.follow {
		t.Error("right on non-openable row cleared follow")
	}

	// Clear ('c') after scrolling up must restore follow.
	send(m, key("c"))
	if !m.follow {
		t.Error("c did not restore follow")
	}

	send(m, RecordMsg(vmservice.Item{Rec: appBoot()}, 0))
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
	pos := m.cursor

	send(m, RecordMsg(vmservice.Item{Rec: stateTrace()}, 0))

	if m.follow || m.cursor != pos {
		t.Errorf("follow = %v, cursor = %d; want false, %d", m.follow, m.cursor, pos)
	}
}

func TestLevelCycleCoversChirpLevelsIncludingCritical(t *testing.T) {
	crit := appBoot()
	crit.Level = "critical"
	crit.Severity = 600
	crit.Message = "zone crash"
	errRec := appBoot()
	errRec.Level = "error"
	errRec.Severity = 500
	errRec.Message = "non-fatal err"

	m := newModel(t, appBoot(), stateTrace(), errRec, crit)
	send(m, key("L")) // ≥debug
	if strings.Contains(screen(m), "demo state") || !strings.Contains(screen(m), "≥debug") {
		t.Errorf("trace visible at ≥debug:\n%s", screen(m))
	}

	// Cycle up to ≥critical (index 7: trace=0, debug=1, info=2, notice=3, success=4, warning=5, error=6, critical=7).
	for range 6 {
		send(m, key("L"))
	}
	s := screen(m)
	if !strings.Contains(s, "≥critical") || !strings.Contains(s, "zone crash") || strings.Contains(s, "non-fatal err") {
		t.Errorf("≥critical did not isolate critical record:\n%s", s)
	}
}

func TestLeftClosesThenJumpsToParent(t *testing.T) {
	m := newModel(t, network())
	send(m, keys("enter", "down", "down", "down", "enter", "down")...) // caller, status, body -> open body -> body.id

	if r, _ := m.current(); r.kind != rowNode || r.node.Key != "id" {
		t.Fatalf("cursor on %+v, want body.id", r)
	}
	send(m, key("left"))
	if r, _ := m.current(); r.node == nil || r.node.Key != "body" {
		t.Fatalf("left from id landed on %+v, want body", r)
	}
	send(m, key("left")) // closes body
	if strings.Contains(screen(m), `"Jane"`) {
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

func TestControlCharactersNeverLeakFromDataKeysOrErrors(t *testing.T) {
	evil := appBoot()
	evil.Data = json.RawMessage("{\"k\\u001b]52;c;aGVsbG8=\\u0007\\nline2\": \"v\u009b2J\"}")
	evil.Error = "err\x1b[2J"
	m := newModel(t, evil)
	send(m, key("e"))
	send(m, ConnMsg(Disconnected, "bad\nline\x1b[2J", 0))

	raw := ansi.Strip(m.View().Content)
	for _, c := range raw {
		if c != '\n' && (c < 0x20 || c == 0x7f || (c >= 0x80 && c < 0xa0)) {
			t.Fatalf("control rune %U leaked into stripped view:\n%q", c, raw)
		}
	}
	if strings.Contains(m.View().Content, "\x1b]52;") {
		t.Fatalf("OSC 52 sequence from JSON key leaked into raw terminal output:\n%q", m.View().Content)
	}
	// View height must equal m.height (status bar pinned at bottom, no extra \n from keys/errors).
	if lines := strings.Split(screen(m), "\n"); len(lines) != m.height {
		t.Errorf("screen has %d lines, want exact height %d:\n%s", len(lines), m.height, screen(m))
	}
}

func TestStylesMeetWCAGContrastOnLightAndDark(t *testing.T) {
	backgrounds := map[string]string{
		"solarized-light": "#fdf6e3",
		"solarized-dark":  "#002b36",
		"soft-gray-light": "#f2f0eb",
		"soft-gray-dark":  "#1e1e1e",
	}
	for colorName, fg := range PaletteHex() {
		for bgName, bg := range backgrounds {
			if ratio := contrastRatio(fg, bg); ratio < 3.0 {
				t.Errorf("%s (%s) on %s (%s) contrast = %.2f, want >= 3.0",
					colorName, fg, bgName, bg, ratio)
			}
		}
	}
}

func contrastRatio(hexA, hexB string) float64 {
	la, lb := relLum(hexA), relLum(hexB)
	if la < lb {
		la, lb = lb, la
	}
	return (la + 0.05) / (lb + 0.05)
}

func relLum(hex string) float64 {
	hex = strings.TrimPrefix(hex, "#")
	r, _ := strconv.ParseUint(hex[0:2], 16, 8)
	g, _ := strconv.ParseUint(hex[2:4], 16, 8)
	b, _ := strconv.ParseUint(hex[4:6], 16, 8)
	ch := func(v uint64) float64 {
		s := float64(v) / 255.0
		if s <= 0.03928 {
			return s / 12.92
		}
		return math.Pow((s+0.055)/1.055, 2.4)
	}
	return 0.2126*ch(r) + 0.7152*ch(g) + 0.0722*ch(b)
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

func TestResizeClampsCursorAndPinsBottomStatusBar(t *testing.T) {
	m := newModel(t, appBoot(), network(), stateTrace())
	send(m, tea.WindowSizeMsg{Width: 40, Height: 6})

	if m.cursor < m.offset || m.cursor >= m.offset+m.bodyHeight() {
		t.Errorf("cursor %d outside view [%d, %d)", m.cursor, m.offset, m.offset+m.bodyHeight())
	}
	lines := strings.Split(screen(m), "\n")
	if len(lines) != 6 {
		t.Errorf("lines = %d, want 6", len(lines))
	}
	for _, line := range lines {
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

func FuzzViewSafetyAndGeometry(f *testing.F) {
	f.Add("hello\x1b]52;c;pwn\x07", "App\x9b2J", `{"k\x1b[31m":"v\nline2"}`, "err\r\nbad", 60, 12, true)
	f.Add("plain", "Network", `[1,2,3]`, "", 25, 4, false)
	f.Fuzz(func(t *testing.T, msg, layer, rawData, errStr string, w, h int, wrap bool) {
		w = 10 + ((w%200)+200)%200
		h = 3 + ((h%60)+60)%60
		m := New("target\x1b[2J")
		send(m, tea.WindowSizeMsg{Width: w, Height: h})
		r := appBoot()
		r.Message = msg
		r.Layer = layer
		r.Error = errStr
		r.Stack = "frame1\x1b[31m\nframe2\x9b2J"
		if len(rawData) > 0 {
			r.Data = json.RawMessage(rawData)
		}
		send(m, RecordMsg(vmservice.Item{Rec: r}, 0))
		send(m, key("e"))
		if wrap {
			send(m, key("w"))
		}
		plain := screen(m)
		lines := strings.Split(plain, "\n")
		if len(lines) != h {
			t.Fatalf("rendered %d lines, want %d", len(lines), h)
		}
		for i, line := range lines {
			if cw := ansi.StringWidth(line); cw > w {
				t.Fatalf("line %d width = %d, want ≤ %d: %q", i, cw, w, line)
			}
			for _, ch := range line {
				if ch < 0x20 || ch == 0x7f || (ch >= 0x80 && ch <= 0x9f) || ch == '\u2028' || ch == '\u2029' {
					t.Fatalf("line %d leaked control rune %U in %q", i, ch, line)
				}
			}
		}
	})
}
