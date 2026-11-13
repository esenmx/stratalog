// Package ui is strata's Bubble Tea v2 TUI: one collapsed line per record,
// opening into a foldable JSON tree, with a substring filter, a minimum
// level and live follow.
package ui

import (
	"fmt"
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"

	"github.com/esenmx/stratalog/tools/strata/internal/record"
	"github.com/esenmx/stratalog/tools/strata/internal/tree"
	"github.com/esenmx/stratalog/tools/strata/internal/vmservice"
)

// MaxEntries caps retained records; the oldest are dropped and counted.
const MaxEntries = 10_000

const restartedLabel = "session restarted"

// Entry is one record row, or a divider when Divider is set.
type Entry struct {
	Rec     record.Record
	Tree    *tree.Node // Rec.Data, parsed on first open
	Open    bool
	Divider string

	parseErr bool
	stack    *tree.Node
	haystack string // lowercased filter text, built on first match
}

// ConnState is the connection loop's state.
type ConnState int

// Connection states.
const (
	Waiting ConnState = iota
	Connected
	Disconnected
)

type recordMsg struct {
	item      vmservice.Item
	malformed int64
}

type connMsg struct {
	state     ConnState
	detail    string
	malformed int64
}

// RecordMsg delivers one record; malformed is the running count of skipped
// events across connections.
func RecordMsg(it vmservice.Item, malformed int64) tea.Msg {
	return recordMsg{item: it, malformed: malformed}
}

// ConnMsg reports a connection state change; detail is the waited-for path,
// the connected URL, or the disconnect reason.
func ConnMsg(state ConnState, detail string, malformed int64) tea.Msg {
	return connMsg{state: state, detail: detail, malformed: malformed}
}

var levels = []struct {
	name     string
	severity int
}{
	{"trace", 0},
	{"debug", 100},
	{"info", 200},
	{"warning", 400},
	{"error", 500},
}

type rowKind int

const (
	rowHeader rowKind = iota
	rowDivider
	rowCaller
	rowText
	rowErrorText
	rowStackLine
	rowErrorLabel
	rowStackLabel // node: the stack, foldable
	rowNode       // node: a Data tree node
)

type row struct {
	kind   rowKind
	entry  *Entry
	node   *tree.Node
	text   string
	depth  int
	index  int // array element index, -1 otherwise
	parent int // rows back to the parent row; 0 = none
}

// Model is the TUI state.
type Model struct {
	target string

	entries []*Entry
	rows    []row // visible rows; rebuilt when dirty, appended per record
	dirty   bool

	cursor, offset int
	follow         bool

	filter    textinput.Model
	filtering bool
	query     string // lowercased applied filter
	level     int    // index into levels

	state       ConnState
	stateDetail string
	connections int
	records     int // entries that are not dividers
	dropped     int
	malformed   int64
	warning     string

	width, height int
}

// New returns a model waiting for target.
func New(target string) *Model {
	in := textinput.New()
	in.Prompt = "/"
	in.Placeholder = "filter layer, message, data, error, stack"
	return &Model{target: target, follow: true, filter: in, stateDetail: target}
}

// Init implements tea.Model.
func (m *Model) Init() tea.Cmd { return nil }

// Update implements tea.Model.
func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.filter.SetWidth(max(msg.Width-2, 1))
	case recordMsg:
		m.malformed = msg.malformed
		m.addRecord(msg.item)
	case connMsg:
		m.malformed = msg.malformed
		if msg.state == Connected {
			if m.connections > 0 && len(m.entries) > 0 {
				m.addEntry(&Entry{Divider: restartedLabel})
			}
			m.connections++
		}
		m.state, m.stateDetail = msg.state, msg.detail
	case tea.KeyPressMsg:
		if m.filtering {
			cmd = m.filterKey(msg)
		} else {
			cmd = m.key(msg)
		}
	case tea.MouseWheelMsg:
		m.wheel(msg.Mouse().Button)
	default:
		if m.filtering {
			m.filter, cmd = m.filter.Update(msg)
		}
	}
	m.settle()
	return m, cmd
}

func (m *Model) filterKey(msg tea.KeyPressMsg) tea.Cmd {
	switch msg.String() {
	case "enter":
		m.filtering = false
		m.filter.Blur()
		return nil
	case "esc":
		m.filtering = false
		m.filter.Blur()
		m.filter.Reset()
		m.setQuery("")
		return nil
	case "ctrl+c":
		return tea.Quit
	}
	var cmd tea.Cmd
	m.filter, cmd = m.filter.Update(msg)
	m.setQuery(m.filter.Value())
	return cmd
}

func (m *Model) key(msg tea.KeyPressMsg) tea.Cmd {
	switch msg.String() {
	case "q", "ctrl+c":
		return tea.Quit
	case "up", "k":
		m.cursor--
		m.follow = false
	case "down", "j":
		m.cursor++
	case "G", "end":
		m.follow = true
	case "g", "home":
		m.cursor, m.offset = 0, 0
		m.follow = false
	case "enter", "space":
		m.toggle()
	case "right", "l":
		m.open()
	case "left", "h":
		m.closeOrParent()
	case "e":
		m.expandAll()
	case "/":
		m.filtering = true
		return m.filter.Focus()
	case "esc":
		m.filter.Reset()
		m.setQuery("")
	case "L":
		m.level = (m.level + 1) % len(levels)
		m.dirty = true
	case "c":
		m.entries, m.rows = nil, nil
		m.cursor, m.offset, m.records, m.dropped = 0, 0, 0, 0
	}
	return nil
}

func (m *Model) setQuery(q string) {
	q = strings.ToLower(q)
	if q != m.query {
		m.query = q
		m.dirty = true
	}
}

func (m *Model) wheel(b tea.MouseButton) {
	switch b {
	case tea.MouseWheelUp:
		m.offset -= 3
		m.follow = false
	case tea.MouseWheelDown:
		m.offset += 3
	default:
		return
	}
	h := m.bodyHeight()
	m.offset = clamp(m.offset, 0, max(len(m.rows)-h, 0))
	m.cursor = clamp(m.cursor, m.offset, m.offset+h-1)
}

func (m *Model) current() (row, bool) {
	if m.cursor < 0 || m.cursor >= len(m.rows) {
		return row{}, false
	}
	return m.rows[m.cursor], true
}

// toggle opens or closes the record or node under the cursor.
func (m *Model) toggle() {
	r, ok := m.current()
	if !ok {
		return
	}
	switch {
	case r.kind == rowHeader && r.entry.openable():
		r.entry.Open = !r.entry.Open
	case (r.kind == rowNode || r.kind == rowStackLabel) && r.node.Foldable():
		r.node.Open = !r.node.Open
	default:
		return
	}
	m.follow = false
	m.dirty = true
}

// open opens the row under the cursor, or steps into it when already open.
func (m *Model) open() {
	r, ok := m.current()
	if !ok {
		return
	}
	m.follow = false
	switch {
	case r.kind == rowHeader && r.entry.openable():
		if r.entry.Open {
			m.cursor++
			return
		}
		r.entry.Open = true
	case (r.kind == rowNode || r.kind == rowStackLabel) && r.node.Foldable():
		if r.node.Open {
			m.cursor++
			return
		}
		r.node.Open = true
	default:
		return
	}
	m.dirty = true
}

// closeOrParent closes the open row under the cursor, else jumps to its
// parent.
func (m *Model) closeOrParent() {
	r, ok := m.current()
	if !ok {
		return
	}
	m.follow = false
	switch {
	case r.kind == rowHeader && r.entry.Open:
		r.entry.Open = false
		m.dirty = true
	case (r.kind == rowNode || r.kind == rowStackLabel) && r.node.Foldable() && r.node.Open:
		r.node.Open = false
		m.dirty = true
	case r.parent > 0:
		m.cursor -= r.parent
	}
}

// expandAll opens everything in the record under the cursor, or, when all
// of it is already open, closes it back to its header.
func (m *Model) expandAll() {
	r, ok := m.current()
	if !ok || r.entry.Divider != "" || !r.entry.openable() {
		return
	}
	e := r.entry
	m.follow = false
	m.dirty = true
	if e.Open && e.fullyOpen() {
		e.Open = false
		if t := e.tree(); t != nil {
			t.SetOpenAll(false)
			t.Open = true
		}
		if s := e.stackNode(); s != nil {
			s.Open = false
		}
		m.rebuild()
		m.cursor = m.headerRow(e)
		return
	}
	e.Open = true
	if t := e.tree(); t != nil {
		t.SetOpenAll(true)
	}
	if s := e.stackNode(); s != nil {
		s.Open = true
	}
}

func (m *Model) headerRow(e *Entry) int {
	for i, r := range m.rows {
		if r.entry == e && r.kind == rowHeader {
			return i
		}
	}
	return m.cursor
}

func (m *Model) addRecord(it vmservice.Item) {
	if it.Rec.V > record.SchemaVersion && m.warning == "" {
		m.warning = fmt.Sprintf("record schema v%d is newer than this strata (v%d): update strata", it.Rec.V, record.SchemaVersion)
	}
	if it.Restarted && len(m.entries) > 0 {
		m.addEntry(&Entry{Divider: restartedLabel})
	}
	m.addEntry(&Entry{Rec: it.Rec})
}

// addEntry appends e, dropping the oldest entry past [MaxEntries]. Rows are
// patched in place unless a full rebuild is already pending.
func (m *Model) addEntry(e *Entry) {
	m.entries = append(m.entries, e)
	if e.Divider == "" {
		m.records++
	}
	if !m.dirty && m.visible(e) {
		m.rows = m.appendEntryRows(m.rows, e)
	}
	if len(m.entries) <= MaxEntries {
		return
	}
	old := m.entries[0]
	m.entries[0] = nil
	m.entries = m.entries[1:]
	if old.Divider == "" {
		m.records--
		m.dropped++
	}
	if m.dirty {
		return
	}
	n := 0
	for n < len(m.rows) && m.rows[n].entry == old {
		n++
	}
	m.rows = m.rows[n:]
	m.cursor -= n
	m.offset -= n
}

func (m *Model) visible(e *Entry) bool {
	if e.Divider != "" {
		return true
	}
	if e.Rec.Severity < levels[m.level].severity {
		return false
	}
	return m.query == "" || strings.Contains(e.search(), m.query)
}

func (m *Model) rebuild() {
	rows := make([]row, 0, len(m.rows))
	for _, e := range m.entries {
		if m.visible(e) {
			rows = m.appendEntryRows(rows, e)
		}
	}
	m.rows = rows
	m.dirty = false
}

// settle rebuilds pending rows, applies follow and keeps the cursor on
// screen.
func (m *Model) settle() {
	if m.dirty {
		m.rebuild()
	}
	if m.follow {
		m.cursor = len(m.rows) - 1
	}
	m.cursor = clamp(m.cursor, 0, max(len(m.rows)-1, 0))
	h := m.bodyHeight()
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+h {
		m.offset = m.cursor - h + 1
	}
	m.offset = clamp(m.offset, 0, max(len(m.rows)-h, 0))
}

func (m *Model) bodyHeight() int {
	h := m.height - 1 // status line
	if m.filtering {
		h--
	}
	return max(h, 1)
}

func (m *Model) appendEntryRows(rows []row, e *Entry) []row {
	if e.Divider != "" {
		return append(rows, row{kind: rowDivider, entry: e, text: e.Divider, index: -1})
	}
	header := len(rows)
	rows = append(rows, row{kind: rowHeader, entry: e, index: -1})
	if !e.Open {
		return rows
	}
	child := func(kind rowKind, text string, parent int) row {
		return row{kind: kind, entry: e, text: text, index: -1, parent: len(rows) - parent}
	}
	if e.Rec.File != "" {
		at := fmt.Sprintf("%s:%d", e.Rec.File, e.Rec.Line)
		if e.Rec.Method != "" {
			at += " " + e.Rec.Method
		}
		rows = append(rows, child(rowCaller, at, header))
	}
	if _, rest, ok := strings.Cut(e.Rec.Message, "\n"); ok {
		for line := range strings.SplitSeq(rest, "\n") {
			rows = append(rows, child(rowText, line, header))
		}
	}
	if len(e.Rec.Data) > 0 {
		if t := e.tree(); t != nil {
			rows = appendTree(rows, e, t, 0, header)
		} else {
			rows = append(rows, child(rowText, string(e.Rec.Data), header))
		}
	}
	if e.Rec.Error != "" {
		label := len(rows)
		rows = append(rows, child(rowErrorLabel, "Error:", header))
		for line := range strings.SplitSeq(e.Rec.Error, "\n") {
			rows = append(rows, child(rowErrorText, line, label))
		}
	}
	if s := e.stackNode(); s != nil {
		label := len(rows)
		r := child(rowStackLabel, "Stack Trace:", header)
		r.node = s
		rows = append(rows, r)
		if s.Open {
			for _, line := range s.Children {
				rows = append(rows, child(rowStackLine, line.Literal, label))
			}
		}
	}
	return rows
}

func appendTree(rows []row, e *Entry, n *tree.Node, depth, parent int) []row {
	if !n.Open {
		return rows
	}
	for i, c := range n.Children {
		index := -1
		if n.Kind == tree.Array {
			index = i
		}
		self := len(rows)
		rows = append(rows, row{kind: rowNode, entry: e, node: c, depth: depth, index: index, parent: self - parent})
		rows = appendTree(rows, e, c, depth+1, self)
	}
	return rows
}

func (e *Entry) openable() bool {
	r := e.Rec
	return e.Divider == "" &&
		(len(r.Data) > 0 || r.Error != "" || r.Stack != "" || r.File != "" || strings.Contains(r.Message, "\n"))
}

func (e *Entry) tree() *tree.Node {
	if e.Tree == nil && !e.parseErr && len(e.Rec.Data) > 0 {
		t, err := tree.Parse(e.Rec.Data)
		if err != nil {
			e.parseErr = true
			return nil
		}
		e.Tree = t
	}
	return e.Tree
}

// stackNode is the stack trace as one closed node whose children are its
// lines.
func (e *Entry) stackNode() *tree.Node {
	if e.stack == nil && e.Rec.Stack != "" {
		s := &tree.Node{Key: "Stack Trace", Kind: tree.Array}
		for line := range strings.SplitSeq(strings.TrimRight(e.Rec.Stack, "\n"), "\n") {
			s.Children = append(s.Children, &tree.Node{Kind: tree.Scalar, Literal: line})
		}
		e.stack = s
	}
	return e.stack
}

func (e *Entry) fullyOpen() bool {
	if t := e.tree(); t != nil && !allOpen(t) {
		return false
	}
	if s := e.stackNode(); s != nil && !s.Open {
		return false
	}
	return true
}

func allOpen(n *tree.Node) bool {
	if n.Foldable() && !n.Open {
		return false
	}
	for _, c := range n.Children {
		if !allOpen(c) {
			return false
		}
	}
	return true
}

func (e *Entry) search() string {
	if e.haystack == "" {
		r := e.Rec
		e.haystack = strings.ToLower(strings.Join([]string{r.Layer, r.Message, string(r.Data), r.Error, r.Stack}, "\n"))
	}
	return e.haystack
}

var (
	dimStyle     = lipgloss.NewStyle().Faint(true)
	keyStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("#87afd7"))
	stringStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#87d787"))
	literalStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#d7afff"))
	errorStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("#ff5f5f"))
	cursorStyle  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#ffd75f"))
	statusStyle  = lipgloss.NewStyle().Reverse(true)
)

// View implements tea.Model.
func (m *Model) View() tea.View {
	var b strings.Builder
	h := m.bodyHeight()
	if len(m.rows) == 0 {
		b.WriteString(dimStyle.Render(m.emptyText()))
		b.WriteByte('\n')
		h--
	}
	for i := m.offset; i < len(m.rows) && i < m.offset+h; i++ {
		b.WriteString(m.truncate(m.renderRow(i)))
		b.WriteByte('\n')
	}
	if m.filtering {
		b.WriteString(m.truncate(m.filter.View()))
		b.WriteByte('\n')
	}
	b.WriteString(statusStyle.Render(m.truncate(m.statusText())))

	v := tea.NewView(b.String())
	v.AltScreen = true
	v.MouseMode = tea.MouseModeCellMotion
	return v
}

func (m *Model) truncate(s string) string {
	if m.width <= 0 {
		return s
	}
	return ansi.Truncate(s, m.width, "…")
}

func (m *Model) emptyText() string {
	switch {
	case len(m.entries) > 0:
		return "no records match"
	case m.state == Connected:
		return "connected, no records yet"
	default:
		return "waiting for " + m.target
	}
}

func (m *Model) statusText() string {
	parts := []string{m.stateText(), fmt.Sprintf("%d records", m.records)}
	if m.dropped > 0 {
		parts = append(parts, fmt.Sprintf("dropped %d", m.dropped))
	}
	if m.malformed > 0 {
		parts = append(parts, fmt.Sprintf("malformed %d", m.malformed))
	}
	parts = append(parts, "≥"+levels[m.level].name)
	if m.query != "" && !m.filtering {
		parts = append(parts, "/"+m.query)
	}
	if m.follow {
		parts = append(parts, "following")
	}
	if m.warning != "" {
		parts = append(parts, m.warning)
	}
	return " " + strings.Join(parts, " · ") + " "
}

func (m *Model) stateText() string {
	switch m.state {
	case Connected:
		return "connected"
	case Disconnected:
		return "disconnected: " + m.stateDetail
	default:
		return "waiting for " + m.stateDetail
	}
}

func (m *Model) renderRow(i int) string {
	r := m.rows[i]
	gutter := "  "
	if i == m.cursor {
		gutter = cursorStyle.Render("❯ ")
	}
	const indent = "    "
	switch r.kind {
	case rowHeader:
		return gutter + header(r.entry)
	case rowDivider:
		line := "── " + r.text + " "
		return gutter + dimStyle.Render(line+strings.Repeat("─", max(m.width-ansi.StringWidth(line)-2, 0)))
	case rowCaller:
		return gutter + indent + dimStyle.Render("at "+r.text)
	case rowText:
		return gutter + indent + r.text
	case rowErrorLabel:
		return gutter + indent + errorStyle.Bold(true).Render(r.text)
	case rowErrorText:
		return gutter + indent + "  " + errorStyle.Render(r.text)
	case rowStackLabel:
		return gutter + indent + marker(r.node) + errorStyle.Render(r.text) + " " + dimStyle.Render(r.node.Summary())
	case rowStackLine:
		return gutter + indent + "    " + dimStyle.Render(r.text)
	case rowNode:
		return gutter + indent + strings.Repeat("  ", r.depth) + marker(r.node) + label(r) + value(r.node)
	}
	return gutter
}

func header(e *Entry) string {
	r := e.Rec
	mark := "  "
	if e.openable() {
		mark = "▸ "
		if e.Open {
			mark = "▾ "
		}
	}
	badge := lipgloss.NewStyle().Bold(true)
	if r.Color != "" {
		badge = badge.Background(lipgloss.Color(r.Color))
	}
	if r.OnColor != "" {
		badge = badge.Foreground(lipgloss.Color(r.OnColor))
	}
	level := "[" + r.Level + "]"
	if r.LevelColor != "" {
		level = lipgloss.NewStyle().Foreground(lipgloss.Color(r.LevelColor)).Render(level)
	}
	return mark + badge.Render(" "+r.Layer+" ") + " " + level + " " +
		dimStyle.Render(r.Time.Local().Format("15:04:05.000")) + " " + r.FirstLine()
}

func marker(n *tree.Node) string {
	switch {
	case !n.Foldable():
		return "  "
	case n.Open:
		return "▾ "
	default:
		return "▸ "
	}
}

func label(r row) string {
	if r.index >= 0 {
		return dimStyle.Render(fmt.Sprintf("%d: ", r.index))
	}
	return keyStyle.Render(r.node.Key) + ": "
}

func value(n *tree.Node) string {
	switch {
	case n.Kind != tree.Scalar:
		return dimStyle.Render(n.Summary())
	case strings.HasPrefix(n.Literal, `"`):
		return stringStyle.Render(n.Literal)
	case n.Literal == "true" || n.Literal == "false" || n.Literal == "null":
		return literalStyle.Render(n.Literal)
	default:
		return n.Literal
	}
}

func clamp(v, lo, hi int) int { return min(max(v, lo), hi) }
