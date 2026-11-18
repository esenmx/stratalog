package ui

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"charm.land/bubbles/v2/cursor"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"pgregory.net/rapid"

	"github.com/esenmx/stratalog/tools/strata/record"
	"github.com/esenmx/stratalog/tools/strata/vmservice"
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
	case "ctrl+u", "ctrl+d", "ctrl+b", "ctrl+f":
		return tea.KeyPressMsg{Code: rune(name[len(name)-1]), Mod: tea.ModCtrl}
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

func TestWrapJumpToEndScrollsInBoundedTime(t *testing.T) {
	m := New("./.flutter.vmservice")
	send(m, tea.WindowSizeMsg{Width: 40, Height: 20})
	const n = 3000
	for i := range n {
		r := appBoot()
		r.Seq = int64(i)
		r.Message = fmt.Sprintf("record %d with a message long enough to wrap twice at forty", i)
		send(m, RecordMsg(vmservice.Item{Rec: r}, 0))
	}
	send(m, keys("w", "g")...)

	start := time.Now()
	send(m, key("G"))
	// Settling under wrap must cost O(screen), not O(rows²): the quadratic
	// walk took ~20 s here.
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("G under wrap took %v over %d rows", d, n)
	}
	if m.cursor != len(m.rows)-1 || !strings.Contains(screen(m), fmt.Sprintf("%d with a message", n-1)) {
		t.Errorf("last record not on screen after G under wrap:\n%s", screen(m))
	}
	span := 0
	for i := m.offset; i <= m.cursor; i++ {
		span += len(m.wrappedLines(i))
	}
	if span > m.bodyHeight() || (m.offset > 0 && span+len(m.wrappedLines(m.offset-1)) <= m.bodyHeight()) {
		t.Errorf("rows %d..%d span %d lines; body holds %d and must be filled", m.offset, m.cursor, span, m.bodyHeight())
	}
}

func TestPasteIntoFilterAppliesQuery(t *testing.T) {
	m := newModel(t, appBoot(), network(), stateTrace())

	send(m, key("/"), tea.PasteMsg{Content: "Jane"}, key("enter"))

	if m.query != "jane" || len(m.rows) != 1 {
		t.Errorf("after pasting Jane: query = %q, rows = %d; want %q, 1", m.query, len(m.rows), "jane")
	}
	if s := screen(m); !strings.Contains(s, "/jane") {
		t.Errorf("status bar lacks the pasted query:\n%s", s)
	}
}

func TestReopenedFilterKeepsFollowUntilQueryChanges(t *testing.T) {
	m := newModel(t, appBoot(), network(), stateTrace())
	send(m, key("/"))
	send(m, typed("Jane")...)
	send(m, keys("enter", "G")...)
	if !m.follow {
		t.Fatal("G did not restore follow")
	}

	send(m, key("/"), key("left"), cursor.BlinkMsg{})

	if !m.follow || m.query != "jane" {
		t.Errorf("follow = %v, query = %q after reopening the filter without editing; want true, %q", m.follow, m.query, "jane")
	}
}

func TestWheelScrollsWrappedRows(t *testing.T) {
	m := New("./.flutter.vmservice")
	send(m, tea.WindowSizeMsg{Width: 40, Height: 21})
	const n = 200
	for i := range n {
		r := appBoot()
		r.Seq = int64(i)
		r.Message = fmt.Sprintf("record %d with a message long enough to wrap twice at forty", i)
		send(m, RecordMsg(vmservice.Item{Rec: r}, 0))
	}
	send(m, key("w"))
	wheel := func(b tea.MouseButton) tea.Msg { return tea.MouseWheelMsg{Button: b} }

	top := m.offset
	for range 5 {
		send(m, wheel(tea.MouseWheelUp))
	}
	if m.offset >= top {
		t.Errorf("5 wheel-ups under wrap left offset at %d, want above %d", m.offset, top)
	}

	send(m, key("g"))
	for range n {
		send(m, wheel(tea.MouseWheelDown))
	}
	if s := screen(m); !strings.Contains(s, fmt.Sprintf("record %d", n-1)) {
		t.Errorf("wheel-down under wrap never reached the last record:\n%s", s)
	}
}

func TestCursorSurvivesRebuildThroughZeroRows(t *testing.T) {
	setup := func(t *testing.T) *Model {
		t.Helper()
		m := newModel(t)
		for i := range 50 {
			r := appBoot()
			r.Seq = int64(i + 1)
			r.Message = fmt.Sprintf("r%d", i)
			send(m, RecordMsg(vmservice.Item{Rec: r}, 0))
		}
		send(m, key("g"))
		for range 30 {
			send(m, key("down"))
		}
		return m
	}
	for name, steps := range map[string][]tea.Msg{
		"level cycle": keys("L", "L", "L", "L", "L", "L", "L", "L", "L"),
		"filter typo": append(append([]tea.Msg{key("/")}, typed("r3zz")...),
			tea.KeyPressMsg{Code: tea.KeyBackspace}, tea.KeyPressMsg{Code: tea.KeyBackspace}, key("esc")),
	} {
		t.Run(name, func(t *testing.T) {
			m := setup(t)
			send(m, steps...)
			r, ok := m.current()
			if !ok {
				t.Fatal("no cursor row after passing through zero rows")
			}
			if got := r.entry.Rec.Message; got != "r30" {
				t.Errorf("cursor on %q after passing through zero rows, want r30", got)
			}
		})
	}
}

func TestCursorStaysOnItsLineInsideMultiLineBlocksAcrossRebuilds(t *testing.T) {
	r := appBoot()
	r.Message = "m1\nm2\nm3"
	r.Data = json.RawMessage(`{"sql":"s1\ns2\ns3"}`)
	r.Error = "e1\ne2\ne3"
	r.Stack = "f1\nf2\nf3\nf4\nf5"
	for _, line := range []string{"m3", "s3", "e3", "f4"} {
		for name, trigger := range map[string]tea.Msg{
			"level":   key("L"),
			"restart": RecordMsg(vmservice.Item{Rec: appBoot(), Restarted: true}, 0),
		} {
			t.Run(line+"/"+name, func(t *testing.T) {
				m := newModel(t, r)
				send(m, keys("e", "g")...)
				for range len(m.rows) {
					if m.rows[m.cursor].text == line {
						break
					}
					send(m, key("down"))
				}
				if m.rows[m.cursor].text != line {
					t.Fatalf("no row %q", line)
				}
				send(m, trigger)
				if got := m.rows[m.cursor].text; got != line {
					t.Errorf("cursor moved from %q to %q", line, got)
				}
			})
		}
	}
}

func TestRestartDividerSurvivesFilteredFirstRecord(t *testing.T) {
	m := newModel(t, appBoot())
	send(m, keys("L", "L")...) // ≥info hides stateTrace
	after := appBoot()
	after.Message = "after restart"

	send(m, RecordMsg(vmservice.Item{Rec: stateTrace(), Restarted: true}, 0))
	send(m, RecordMsg(vmservice.Item{Rec: after}, 0))

	s := screen(m)
	if strings.Count(s, restartedLabel) != 1 || strings.Index(s, restartedLabel) > strings.Index(s, "after restart") {
		t.Errorf("want one divider above the first shown record after the restart:\n%s", s)
	}
}

func TestCtrlCQuitsInEveryMode(t *testing.T) {
	ctrlC := tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl}
	for name, open := range map[string][]tea.Msg{
		"normal": nil,
		"filter": keys("/"),
		"layer":  keys("f"),
	} {
		t.Run(name, func(t *testing.T) {
			m := newModel(t, appBoot())
			send(m, open...)
			cmd := send(m, ctrlC)
			if cmd == nil {
				t.Fatal("ctrl+c returned no command, want tea.Quit")
			}
			if _, quit := cmd().(tea.QuitMsg); !quit {
				t.Error("ctrl+c did not quit")
			}
		})
	}
}

const tallW, tallH = 80, 24

// tallModel is the 80x24 reproduction: a record whose data holds a
// 4,000-character single-line string, expanded and wrapped, then a short
// record below it, with the cursor on the first header.
func tallModel(t *testing.T) *Model {
	t.Helper()
	return tallModelThen(t, stateTrace())
}

func tallModelThen(t *testing.T, after ...record.Record) *Model {
	t.Helper()
	blob := "THE-START" + strings.Repeat("x", 4000-len("THE-START")-len("THE-END")) + "THE-END"
	r := appBoot()
	r.Data = json.RawMessage(fmt.Sprintf(`{"blob":%q}`, blob))
	m := New("./.flutter.vmservice")
	send(m, tea.WindowSizeMsg{Width: tallW, Height: tallH})
	for _, rec := range append([]record.Record{r}, after...) {
		send(m, RecordMsg(vmservice.Item{Rec: rec}, 0))
	}
	send(m, keys("g", "e", "w")...)
	return m
}

// shows reports whether s is on screen, allowing it to wrap across lines.
func shows(m *Model, s string) bool {
	return strings.Contains(strings.ReplaceAll(screen(m), "\n", ""), s)
}

func onBlob(m *Model) bool {
	r, ok := m.current()
	return ok && r.node != nil && r.node.Key == "blob"
}

func pressUntil(m *Model, msg tea.Msg, s string) bool {
	for range 1000 {
		if shows(m, s) {
			return true
		}
		send(m, msg)
	}
	return shows(m, s)
}

var (
	wheelDown = tea.MouseWheelMsg{Button: tea.MouseWheelDown}
	wheelUp   = tea.MouseWheelMsg{Button: tea.MouseWheelUp}
)

func TestWrapScrollsThroughRowTallerThanBody(t *testing.T) {
	for name, tc := range map[string]struct{ down, up tea.Msg }{
		"keys":  {key("down"), key("up")},
		"vim":   {key("j"), key("k")},
		"wheel": {wheelDown, wheelUp},
	} {
		t.Run(name, func(t *testing.T) {
			m := tallModel(t)
			if !pressUntil(m, tc.down, "THE-END") {
				t.Fatalf("THE-END never shown by moving down:\n%s", screen(m))
			}
			if !onBlob(m) {
				t.Fatalf("THE-END shown with the cursor off the blob row:\n%s", screen(m))
			}
			send(m, tc.down)
			if r, _ := m.current(); r.kind != rowHeader || r.entry.Rec.Layer != "State" {
				t.Fatalf("down past the blob's end landed on %+v, want the next record:\n%s", r, screen(m))
			}
			if !pressUntil(m, tc.up, "THE-START") {
				t.Fatalf("THE-START never shown by moving back up:\n%s", screen(m))
			}
			if first, _, _ := strings.Cut(screen(m), "\n"); !onBlob(m) || !strings.HasPrefix(first, "❯") || !strings.Contains(first, `blob: "THE-`) {
				t.Errorf("back at the blob's top, first line = %q, want the blob row's first line:\n%s", first, screen(m))
			}
		})
	}
}

func TestWrapEnteringTallRowFromBelowShowsItsLastScreenful(t *testing.T) {
	for name, up := range map[string]tea.Msg{
		"key":   key("up"),
		"wheel": wheelUp,
	} {
		t.Run(name, func(t *testing.T) {
			m := tallModel(t)
			send(m, key("G"))
			send(m, up)
			if !onBlob(m) || !shows(m, "THE-END") || shows(m, "THE-START") {
				t.Errorf("entering the blob from below did not show its last screenful:\n%s", screen(m))
			}
		})
	}
}

var linePos = regexp.MustCompile(`line (\d+)-(\d+)/(\d+)`)

func TestWrapStatusShowsLinePositionInsideTallRow(t *testing.T) {
	for name, tc := range map[string]struct {
		width, downs, first int
		end                 bool
	}{
		"caller row":    {width: tallW, downs: 1},
		"blob top":      {width: tallW, downs: 2, first: 1},
		"one line down": {width: tallW, downs: 3, first: 2},
		"blob end":      {width: tallW, end: true},
		"narrow":        {width: 30, downs: 2, first: 1},
	} {
		t.Run(name, func(t *testing.T) {
			m := tallModel(t)
			send(m, tea.WindowSizeMsg{Width: tc.width, Height: tallH})
			for range tc.downs {
				send(m, key("down"))
			}
			if tc.end {
				pressUntil(m, key("down"), "THE-END")
			}
			lines := strings.Split(screen(m), "\n")
			status := lines[len(lines)-1]
			got := linePos.FindStringSubmatch(status)
			if tc.first == 0 && !tc.end {
				if got != nil {
					t.Errorf("status %q shows a line position on a row that fits", status)
				}
				return
			}
			if got == nil {
				t.Fatalf("status %q lacks the line position", status)
			}
			a, _ := strconv.Atoi(got[1])
			b, _ := strconv.Atoi(got[2])
			n, _ := strconv.Atoi(got[3])
			if body := tallH - 1; b-a+1 != body || b > n {
				t.Errorf("status %q: want a %d-line window inside the row", status, body)
			}
			if tc.end && b != n {
				t.Errorf("status %q at THE-END, want the window to end at the last line", status)
			}
			if !tc.end && a != tc.first {
				t.Errorf("status %q, want the window to start at line %d", status, tc.first)
			}
		})
	}
}

func TestWrapTallRowStaysReadableAfterResizeAndWrapToggle(t *testing.T) {
	t.Parallel()
	for name, tc := range map[string]struct {
		msgs []tea.Msg
		want []string
	}{
		"taller":      {msgs: []tea.Msg{tea.WindowSizeMsg{Width: tallW, Height: 80}}, want: []string{"THE-START", "THE-END"}},
		"wider":       {msgs: []tea.Msg{tea.WindowSizeMsg{Width: 160, Height: tallH}}, want: []string{"THE-END"}},
		"shorter":     {msgs: []tea.Msg{tea.WindowSizeMsg{Width: tallW, Height: 8}}},
		"narrower":    {msgs: []tea.Msg{tea.WindowSizeMsg{Width: 30, Height: tallH}}},
		"tiny":        {msgs: []tea.Msg{tea.WindowSizeMsg{Width: 10, Height: 4}}},
		"help bar":    {msgs: keys("?")},
		"wrap off":    {msgs: keys("w"), want: []string{"THE-"}},
		"wrap toggle": {msgs: keys("w", "w"), want: []string{"THE-START"}},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			m := tallModel(t)
			pressUntil(m, key("down"), "THE-END")
			send(m, tc.msgs...)
			for _, s := range tc.want {
				if !shows(m, s) {
					t.Errorf("%s not shown right after the change:\n%s", s, screen(m))
				}
			}
			if got, want := len(strings.Split(screen(m), "\n")), m.height; got != want {
				t.Errorf("screen has %d lines, want %d", got, want)
			}
			if !onBlob(m) {
				t.Fatalf("cursor left the blob row:\n%s", screen(m))
			}
			if !pressUntil(m, key("up"), `blob: "THE-`) || !onBlob(m) {
				t.Errorf("up did not lead back to the blob's first line:\n%s", screen(m))
			}
			if m.wrap && (!pressUntil(m, key("down"), "THE-END") || !onBlob(m)) {
				t.Errorf("down did not lead to the blob's last line:\n%s", screen(m))
			}
		})
	}
}

var token = regexp.MustCompile(`\b[hdz]\d{3}\b`)

func tokens(prefix string, n int) string {
	ts := make([]string, n)
	for i := range ts {
		ts[i] = fmt.Sprintf("%s%03d", prefix, i)
	}
	return strings.Join(ts, " ")
}

func TestWrapEveryLineReachableByDownAloneAndUpAlone(t *testing.T) {
	short := appBoot()
	tallHead := appBoot()
	tallHead.Message = "head " + tokens("h", 120)
	tallData := network()
	tallData.Data = json.RawMessage(fmt.Sprintf(`{"blob":%q,"n":1}`, tokens("d", 150)))
	last := stateTrace()
	last.Message = "last " + tokens("z", 100)
	m := New("./.flutter.vmservice")
	send(m, tea.WindowSizeMsg{Width: 40, Height: 12})
	for _, r := range []record.Record{short, tallHead, tallData, short, last} {
		send(m, RecordMsg(vmservice.Item{Rec: r}, 0))
	}
	send(m, keys("g", "]", "]", "e", "w", "g")...)
	want := token.FindAllString(tokens("h", 120)+" "+tokens("d", 150)+" "+tokens("z", 100), -1)

	// Down runs first in each pair so up starts from the bottom it reached.
	for _, pair := range [][2]string{
		{"down", "up"},
		{"pgdown", "pgup"},
		{"ctrl+f", "ctrl+b"},
		{"ctrl+d", "ctrl+u"},
	} {
		send(m, key("g"))
		for _, name := range pair {
			seen := map[string]bool{}
			for range 400 {
				for _, tok := range token.FindAllString(screen(m), -1) {
					seen[tok] = true
				}
				send(m, key(name))
			}
			var missing []string
			for _, tok := range want {
				if !seen[tok] {
					missing = append(missing, tok)
				}
			}
			if len(missing) > 0 {
				t.Errorf("%s alone never showed %d of %d tokens, first %v", name, len(missing), len(want), missing[0])
			}
		}
	}
}

func TestWrapSingleTallRowScrollsByPageAndHalfPage(t *testing.T) {
	rec := appBoot()
	rec.Message = "SOLO-START " + strings.Repeat("word ", 600) + "SOLO-END"
	for _, pair := range [][2]string{
		{"pgdown", "pgup"},
		{"ctrl+f", "ctrl+b"},
		{"ctrl+d", "ctrl+u"},
	} {
		t.Run(pair[0]+"_"+pair[1], func(t *testing.T) {
			m := New("./.flutter.vmservice")
			send(m, tea.WindowSizeMsg{Width: tallW, Height: tallH}, RecordMsg(vmservice.Item{Rec: rec}, 0))
			send(m, keys("w", "g")...)
			if !shows(m, "SOLO-START") || shows(m, "SOLO-END") {
				t.Fatalf("initial screen did not start at top of solo tall row:\n%s", screen(m))
			}
			if !pressUntil(m, key(pair[0]), "SOLO-END") {
				t.Fatalf("%s never reached SOLO-END on a single tall row:\n%s", pair[0], screen(m))
			}
			if !pressUntil(m, key(pair[1]), "SOLO-START") {
				t.Fatalf("%s never returned to SOLO-START on a single tall row:\n%s", pair[1], screen(m))
			}
		})
	}
}

func TestWrapLineOffSurvivesSiblingFoldAboveCursor(t *testing.T) {
	rec := appBoot()
	rec.Data = json.RawMessage(fmt.Sprintf(`{"a":{"nested":1,"extra":2},"z":%q}`, "THE-START "+strings.Repeat("word ", 600)+"THE-END"))
	m := New("./.flutter.vmservice")
	send(m, tea.WindowSizeMsg{Width: tallW, Height: tallH}, RecordMsg(vmservice.Item{Rec: rec}, 0))
	// Open only the record header (leaving "a" folded), move onto tall "z", and scroll inside it.
	send(m, keys("g", "enter", "w", "down", "down")...)
	for range 5 {
		send(m, key("down"))
	}
	wantLineOff := m.lineOff
	if wantLineOff == 0 {
		t.Fatalf("setup did not advance lineOff inside z:\n%s", screen(m))
	}
	// Pressing "e" expands folded sibling "a" above "z", changing z.parent without leaving z.
	send(m, key("e"))
	if m.lineOff != wantLineOff {
		t.Errorf("expanding sibling above cursor reset lineOff from %d to %d", wantLineOff, m.lineOff)
	}
}

func steppedUp(msg tea.Msg) bool {
	switch msg := msg.(type) {
	case tea.KeyPressMsg:
		switch msg.String() {
		case "up", "k", "pgup", "ctrl+b", "ctrl+u":
			return true
		}
	case tea.MouseWheelMsg:
		return msg.Button == tea.MouseWheelUp
	}
	return false
}

func walkRecord(t *rapid.T, seq int64) tea.Msg {
	r := appBoot()
	r.Seq = seq
	r.Layer = rapid.SampledFrom([]string{"App", "Network", "State"}).Draw(t, "layer")
	lvl := rapid.SampledFrom(record.Levels).Draw(t, "level")
	r.Level, r.Severity = lvl.Name, lvl.Severity
	r.Message = fmt.Sprintf("m%d %s", seq, strings.Repeat("word ", rapid.IntRange(0, 300).Draw(t, "words")))
	switch rapid.SampledFrom([]string{"plain", "data", "error"}).Draw(t, "shape") {
	case "data":
		blob := strings.Repeat("x", rapid.IntRange(0, 5000).Draw(t, "blob"))
		r.Data = json.RawMessage(fmt.Sprintf(`{"blob":%q,"list":[1,2,{"k":"a\nb\nc"}]}`, blob))
	case "error":
		r.Error = strings.Repeat("err ", rapid.IntRange(0, 400).Draw(t, "error"))
		r.Stack = "f1\nf2\n" + strings.Repeat("frame ", rapid.IntRange(0, 300).Draw(t, "frames"))
	}
	return RecordMsg(vmservice.Item{Rec: r, Restarted: rapid.IntRange(0, 19).Draw(t, "restart") == 0}, 0)
}

func TestWrapWalkKeepsBodyAndLineOffsetInBounds(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		m := New("./.flutter.vmservice")
		send(m, tea.WindowSizeMsg{Width: tallW, Height: tallH}, key("w"), key("e"))
		var seq int64
		do := func(msgs ...tea.Msg) {
			for _, msg := range msgs {
				before, _ := m.cursorID()
				send(m, msg)
				checkWalkStep(t, m, before, msg)
			}
		}
		record := func(t *rapid.T) {
			seq++
			do(walkRecord(t, seq))
		}
		for range 3 {
			record(t)
		}
		t.Repeat(map[string]func(*rapid.T){
			"record": record,
			"step": func(t *rapid.T) {
				do(key(rapid.SampledFrom([]string{"up", "down", "j", "k"}).Draw(t, "key")))
			},
			"wheel": func(t *rapid.T) {
				do(rapid.SampledFrom([]tea.Msg{wheelDown, wheelUp}).Draw(t, "wheel"))
			},
			"half page": func(t *rapid.T) {
				do(tea.KeyPressMsg{Code: rapid.SampledFrom([]rune{'u', 'd'}).Draw(t, "key"), Mod: tea.ModCtrl})
			},
			"resize": func(t *rapid.T) {
				do(tea.WindowSizeMsg{Width: rapid.IntRange(1, 140).Draw(t, "width"), Height: rapid.IntRange(1, 50).Draw(t, "height")})
			},
			"filter": func(t *rapid.T) {
				do(key("/"))
				do(typed(rapid.SampledFrom([]string{"m1", "word", "x", "zz"}).Draw(t, "query"))...)
				do(key(rapid.SampledFrom([]string{"enter", "esc"}).Draw(t, "end")))
			},
			"key": func(t *rapid.T) {
				do(key(rapid.SampledFrom([]string{
					"pgup", "pgdown", "ctrl+b", "ctrl+f", "[", "]", "J", "K", "g", "G", "enter", "space", "right", "left",
					"l", "h", "e", "w", "esc", "n", "N", "f", "1", "?", "L", "F", "c",
				}).Draw(t, "key")))
			},
		})
	})
}

func checkWalkStep(t *rapid.T, m *Model, before rowID, msg tea.Msg) {
	bars := 0
	for _, on := range []bool{m.layering, m.filtering, m.showHelp} {
		if on {
			bars++
		}
	}
	if got, want := len(strings.Split(m.View().Content, "\n")), m.bodyHeight()+bars+1; got != want {
		t.Fatalf("%T %v: view has %d lines, want body %d + %d bars + status", msg, msg, got, m.bodyHeight(), bars)
	}
	hi := 0
	if m.wrap && len(m.rows) > 0 {
		hi = max(len(m.wrappedLines(m.cursor))-m.bodyHeight(), 0)
	}
	if m.lineOff < 0 || m.lineOff > hi || (m.lineOff > 0 && m.offset != m.cursor) {
		t.Fatalf("%T %v: lineOff %d outside [0, %d] or offset %d != cursor %d", msg, msg, m.lineOff, hi, m.offset, m.cursor)
	}
	after, _ := m.cursorID()
	switch {
	case m.follow && m.lineOff != hi:
		t.Fatalf("%T %v: following at lineOff %d, want the last screenful %d", msg, msg, m.lineOff, hi)
	case !m.follow && after != before && m.lineOff != 0 && !steppedUp(msg):
		t.Fatalf("%T %v: moved to another row at lineOff %d, want its first line", msg, msg, m.lineOff)
	}
}

func TestWrapTallCursorDoesNotStallIncomingRecords(t *testing.T) {
	huge := appBoot()
	huge.Message = strings.Repeat("segment-with-delimiters/a?b=1&c=2 ", 3000) // ~102 KB
	m := New("./.flutter.vmservice")
	send(m, tea.WindowSizeMsg{Width: tallW, Height: tallH}, RecordMsg(vmservice.Item{Rec: huge}, 0))
	send(m, keys("w", "g", "down")...)
	_ = m.View()

	start := time.Now()
	for i := range 200 {
		r := stateTrace()
		r.Seq = int64(i + 2)
		send(m, RecordMsg(vmservice.Item{Rec: r}, 0))
		_ = m.View()
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("200 incoming records + views with 100 KB cursor row took %v", d)
	}
}

func TestWrapFollowShowsTallLastRowsLastScreenful(t *testing.T) {
	long := appBoot()
	long.Message = "MSG-START " + strings.Repeat("word ", 800) + "MSG-END"
	for name, tc := range map[string]struct {
		after      []record.Record
		then       []tea.Msg
		end, start string
	}{
		"jump to end": {nil, keys("G"), "THE-END", "THE-START"},
		"record arriving while following": {
			[]record.Record{stateTrace()},
			[]tea.Msg{key("G"), RecordMsg(vmservice.Item{Rec: long}, 0)},
			"MSG-END", "MSG-START",
		},
	} {
		t.Run(name, func(t *testing.T) {
			m := tallModelThen(t, tc.after...)
			send(m, tc.then...)
			if !shows(m, tc.end) || shows(m, tc.start) {
				t.Errorf("following did not show the last row's last screenful:\n%s", screen(m))
			}
		})
	}
}

func TestWrapWheelNeverSkipsRowsBesideTallRow(t *testing.T) {
	const after = 30
	recs := make([]record.Record, after)
	for i := range recs {
		recs[i] = appBoot()
		recs[i].Message = fmt.Sprintf("after %02d", i+1)
	}
	m := tallModelThen(t, recs...)

	if !pressUntil(m, wheelDown, "THE-END") {
		t.Fatalf("wheel never reached THE-END:\n%s", screen(m))
	}
	send(m, wheelDown)
	if r, _ := m.current(); r.entry.Rec.Message != "after 01" || !shows(m, "after 01") {
		t.Errorf("wheel past the blob's end landed on %q, want after 01:\n%s", r.entry.Rec.Message, screen(m))
	}

	send(m, key("G"))
	seen := map[string]bool{}
	for range 1000 {
		if shows(m, "THE-END") {
			break
		}
		for i := range after {
			if s := fmt.Sprintf("after %02d", i+1); shows(m, s) {
				seen[s] = true
			}
		}
		send(m, wheelUp)
	}
	for i := range after {
		if s := fmt.Sprintf("after %02d", i+1); !seen[s] {
			t.Errorf("wheel up from the bottom reached THE-END without ever showing %s", s)
		}
	}
}

type cell struct{ s, fg string }

// cells replays a view the way Bubble Tea's renderer does, carrying SGR state
// across newlines, and returns each printed grapheme with its foreground.
func cells(view string) [][]cell {
	lines := [][]cell{nil}
	fg := ""
	var state byte
	for view != "" {
		seq, width, n, next := ansi.DecodeSequence(view, state, nil)
		state, view = next, view[n:]
		switch {
		case seq == "\n":
			lines = append(lines, nil)
		case width > 0:
			lines[len(lines)-1] = append(lines[len(lines)-1], cell{seq, fg})
		case ansi.HasCsiPrefix(seq) && strings.HasSuffix(seq, "m"):
			fg = sgrForeground(fg, strings.Split(seq[2:len(seq)-1], ";"))
		}
	}
	return lines
}

func sgrForeground(fg string, ps []string) string {
	for i := 0; i < len(ps); i++ {
		switch p := ps[i]; p {
		case "", "0", "39":
			fg = ""
		case "38", "48":
			n := 2
			if i+1 < len(ps) && ps[i+1] == "2" {
				n = 4
			}
			if p == "38" {
				fg = strings.Join(ps[i+1:min(i+1+n, len(ps))], ";")
			}
			i += n
		default:
			if v, err := strconv.Atoi(p); err == nil && (v >= 30 && v <= 37 || v >= 90 && v <= 97) {
				fg = p
			}
		}
	}
	return fg
}

func TestWrapScrolledTallRowKeepsItsColours(t *testing.T) {
	blob := "Q-" + strings.Repeat("Q", 3998)
	withData := appBoot()
	withData.Data = json.RawMessage(fmt.Sprintf(`{"blob":%q}`, blob))
	withError := appBoot()
	withError.Error = blob
	for name, tc := range map[string]struct {
		rec   record.Record
		style string
	}{
		"string": {withData, stringStyle.Render("Q")},
		"error":  {withError, errorStyle.Render("Q")},
	} {
		t.Run(name, func(t *testing.T) {
			want := cells(tc.style)[0][0].fg
			m := New("./.flutter.vmservice")
			send(m, tea.WindowSizeMsg{Width: tallW, Height: tallH}, RecordMsg(vmservice.Item{Rec: tc.rec}, 0))
			send(m, keys("g", "e", "w")...)
			for range 10 {
				if linePos.MatchString(screen(m)) {
					break
				}
				send(m, key("down"))
			}
			send(m, key("down"))
			if got := linePos.FindString(screen(m)); got != "line 2-24/"+strconv.Itoa(m.maxLineOff()+m.bodyHeight()) {
				t.Fatalf("status shows %q, want one line into the tall row:\n%s", got, screen(m))
			}
			lines := cells(m.View().Content)
			painted := 0
			for y, line := range lines[:m.bodyHeight()] {
				for x, c := range line {
					if c.s == "Q" && c.fg != want {
						t.Fatalf("body cell %d,%d drawn in %q, want %q", y, x, c.fg, want)
					}
					if c.s == "Q" {
						painted++
					}
				}
			}
			if painted < m.bodyHeight()*tallW/2 {
				t.Errorf("only %d cells of the tall row on screen", painted)
			}
			for x, c := range lines[len(lines)-1] {
				if c.fg != "" {
					t.Fatalf("status bar cell %d drawn in %q, want the default foreground", x, c.fg)
				}
			}
		})
	}
}

func TestWrapWheelInsideTallRowScrollsByItsStep(t *testing.T) {
	for name, wheels := range map[string][]tea.Msg{
		"down":         {wheelDown},
		"down then up": {wheelDown, wheelDown, wheelUp},
	} {
		t.Run(name, func(t *testing.T) {
			m := tallModel(t)
			send(m, keys("down", "down")...)
			send(m, wheels...)
			if got, want := linePos.FindString(screen(m)), fmt.Sprintf("line %d-", 1+wheelStep); !strings.HasPrefix(got, want) {
				t.Errorf("status shows %q, want %q…: one wheel step into the row", got, want)
			}
		})
	}
}

func TestWrapJumpOntoAnotherTallRowOpensAtItsFirstLine(t *testing.T) {
	second := appBoot()
	second.Message = "SECOND-HEAD " + strings.Repeat("y", 4000)
	m := tallModelThen(t, second)
	send(m, keys("down", "down")...)
	for range 10 {
		send(m, key("down"))
	}
	send(m, key("]"))
	if r, _ := m.current(); r.kind != rowHeader || !shows(m, "SECOND-HEAD") {
		t.Errorf("] from inside the blob landed on %+v without its first line:\n%s", r, screen(m))
	}
}

func TestWrapEnteringTallRowFromAboveAfterAnUpShowsItsFirstScreenful(t *testing.T) {
	m := tallModel(t)
	send(m, keys("G", "up", "g", "down", "down")...)
	if !onBlob(m) || !shows(m, "THE-START") {
		t.Errorf("entering the blob from above after an earlier up did not show its first screenful:\n%s", screen(m))
	}
}
