// Package ui implements strata's Bubble Tea v2 TUI: one collapsed line per
// record with vital-key previews, opening into a foldable JSON & multi-line
// scalar tree, with layer/level/substring filters, soft-wrap, OSC 52 copy, and
// live follow.
package ui

import (
	"fmt"
	"maps"
	"slices"
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"

	"github.com/esenmx/stratalog/tools/strata/record"
	"github.com/esenmx/stratalog/tools/strata/termsafe"
	"github.com/esenmx/stratalog/tools/strata/tree"
	"github.com/esenmx/stratalog/tools/strata/vmservice"
)

// MaxEntries caps retained records; the oldest are dropped and counted.
const MaxEntries = 10_000

const restartedLabel = "session restarted"

// Palette hex values drawn from stratalog's WCAG-verified Ansi256 palette
// (>= 3.0 contrast on solarized light/dark and soft-gray light/dark).
const (
	hexKey     = "#0087ff" // Ansi256.dodgerBlue1_33
	hexString  = "#00875f" // Ansi256.springGreen4_29
	hexLiteral = "#875fff" // Ansi256.slateBlue1_99
	hexError   = "#d75f5f" // Ansi256.indianRed_167
	hexCursor  = "#d75f00" // Ansi256.darkOrange3_166
)

// PaletteHex exposes the foreground hex colors used by the TUI so tests can
// enforce WCAG >= 3.0 contrast across light and dark reference backgrounds.
func PaletteHex() map[string]string {
	return map[string]string{
		"key":     hexKey,
		"string":  hexString,
		"literal": hexLiteral,
		"error":   hexError,
		"cursor":  hexCursor,
	}
}

var (
	dimStyle     = lipgloss.NewStyle().Faint(true)
	keyStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color(hexKey))
	stringStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color(hexString))
	literalStyle = lipgloss.NewStyle().Foreground(lipgloss.Color(hexLiteral))
	errorStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color(hexError))
	cursorStyle  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color(hexCursor))
	matchStyle   = lipgloss.NewStyle().Bold(true).Underline(true)
	statusStyle  = lipgloss.NewStyle().Reverse(true)
)

// Options configures a [Model]'s initial filters and target mode.
type Options struct {
	Target string
	Level  int             // index into [record.Levels]
	Layers map[string]bool // lowercased layer names; nil/empty = all
	Query  string          // initial substring filter
	Replay bool            // static capture file or stdin (not live-streaming)
}

// Entry is one record row, or a divider when Divider is set.
type Entry struct {
	Rec     record.Record
	Tree    *tree.Node // Rec.Data, parsed on first touch
	Open    bool
	Divider string

	parseErr    bool
	previewDone bool
	previewText string
	stack       *tree.Node
	haystack    string // lowercased filter text, built on first match
}

// ConnState is the connection loop's state.
type ConnState int

// Connection states.
const (
	Waiting ConnState = iota
	Connected
	Disconnected
	Replaying
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
	rowScalarLine // unfolded line of a multi-line string node
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

// anchor pins the cursor to a row across rebuilds.
type anchor struct {
	row
	nth int // ordinal among the entry's rows sharing node and kind
	seq int // the row's entry position in entryIdx
}

func (r row) sameSlot(o row) bool {
	return r.entry == o.entry && r.node == o.node && r.kind == o.kind
}

type layerBadge struct {
	name    string
	color   string
	onColor string
}

// Model is the TUI state.
type Model struct {
	target string
	replay bool

	entries  []*Entry
	entryIdx map[*Entry]int // chronological position for cursor anchoring
	nextSeq  int

	rows  []row // visible rows; rebuilt when dirty, appended per record
	dirty bool
	// lost is the cursor's anchor while a rebuild leaves no rows to hold it.
	lost *anchor
	// pendingDivider is owed to rows ahead of the next visible record.
	pendingDivider *Entry

	cursor, offset int
	// lineOff is the first wrapped line shown of a cursor row taller than the
	// body; it belongs to lineRow and is 0 for any row that fits.
	lineOff   int
	lineRow   row
	fromBelow bool // the cursor stepped up onto its row this update
	follow    bool
	wrap      bool
	showHelp  bool

	filter    textinput.Model
	filtering bool
	query     string // lowercased applied filter
	level     int    // index into record.Levels

	layering    bool
	layerCursor int
	layers      map[string]bool       // lowercased active layer filter
	knownLayers map[string]layerBadge // lowercased -> display name & palette

	state       ConnState
	stateDetail string
	notice      string // transient status flash (e.g. "copied")
	records     int    // entries that are not dividers
	dropped     int
	malformed   int64
	warning     string

	width, height int
}

// New returns a model waiting for target with default filters.
func New(target string) *Model {
	return NewWithOptions(Options{Target: target})
}

// NewWithOptions returns a model pre-seeded with opts.
func NewWithOptions(opts Options) *Model {
	in := textinput.New()
	in.Prompt = "/"
	in.Placeholder = "filter layer, message, data, error, stack, file"
	q := strings.ToLower(strings.TrimSpace(opts.Query))
	if q != "" {
		in.SetValue(opts.Query)
	}
	layers := map[string]bool{}
	for k, v := range opts.Layers {
		if v {
			layers[strings.ToLower(k)] = true
		}
	}
	lvl := clamp(opts.Level, 0, len(record.Levels)-1)
	st := Waiting
	if opts.Replay {
		st = Replaying
	}
	return &Model{
		target:      opts.Target,
		replay:      opts.Replay,
		entryIdx:    map[*Entry]int{},
		follow:      !opts.Replay,
		filter:      in,
		query:       q,
		level:       lvl,
		layers:      layers,
		knownLayers: map[string]layerBadge{},
		state:       st,
		stateDetail: opts.Target,
	}
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
		m.state, m.stateDetail = msg.state, msg.detail
	case tea.KeyPressMsg:
		m.notice = ""
		switch {
		case msg.String() == "ctrl+c":
			cmd = tea.Quit
		case m.filtering:
			cmd = m.filterKey(msg)
		case m.layering:
			m.layerKey(msg)
		default:
			cmd = m.key(msg)
		}
	case tea.MouseWheelMsg:
		m.wheel(msg.Mouse().Button)
	default:
		if m.filtering {
			cmd = m.updateFilter(msg)
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
	}
	return m.updateFilter(msg)
}

// updateFilter feeds msg to the filter input and applies its value as the
// query on change; pastes arrive as tea.PasteMsg, not key presses.
func (m *Model) updateFilter(msg tea.Msg) tea.Cmd {
	before := m.filter.Value()
	var cmd tea.Cmd
	m.filter, cmd = m.filter.Update(msg)
	if v := m.filter.Value(); v != before {
		if v != "" {
			m.follow = false
		}
		m.setQuery(v)
	}
	return cmd
}

func (m *Model) layerKey(msg tea.KeyPressMsg) {
	list := m.sortedLayers()
	s := msg.String()
	switch s {
	case "enter", "esc", "f":
		m.layering = false
	case "left", "h":
		if len(list) > 0 {
			m.layerCursor = (m.layerCursor - 1 + len(list)) % len(list)
		}
	case "right", "l":
		if len(list) > 0 {
			m.layerCursor = (m.layerCursor + 1) % len(list)
		}
	case "space":
		if m.layerCursor >= 0 && m.layerCursor < len(list) {
			m.toggleLayer(strings.ToLower(list[m.layerCursor].name))
		}
	case "a":
		clear(m.layers)
		m.dirty = true
	default:
		if len(s) == 1 && s[0] >= '1' && s[0] <= '9' {
			idx := int(s[0] - '1')
			if idx < len(list) {
				m.layerCursor = idx
				m.toggleLayer(strings.ToLower(list[idx].name))
			}
		}
	}
}

func (m *Model) toggleLayer(lower string) {
	if m.layers[lower] {
		delete(m.layers, lower)
	} else {
		m.layers[lower] = true
	}
	m.dirty = true
}

func (m *Model) key(msg tea.KeyPressMsg) tea.Cmd {
	switch msg.String() {
	case "q":
		return tea.Quit
	case "up", "k":
		m.follow = false
		switch {
		case m.lineOff > 0:
			m.lineOff--
		case m.cursor > 0:
			m.cursor--
			m.fromBelow = true
		}
	case "down", "j":
		if m.lineOff < m.maxLineOff() {
			m.lineOff++
		} else {
			m.cursor++
		}
	case "pgup", "ctrl+b":
		m.cursor -= max(m.bodyHeight()-1, 1)
		m.follow = false
	case "pgdown", "ctrl+f":
		m.cursor += max(m.bodyHeight()-1, 1)
	case "ctrl+u":
		m.cursor -= max(m.bodyHeight()/2, 1)
		m.follow = false
	case "ctrl+d":
		m.cursor += max(m.bodyHeight()/2, 1)
	case "[", "K":
		m.jumpRecord(-1)
	case "]", "J":
		m.jumpRecord(1)
	case "G", "end":
		m.follow = true
	case "g", "home":
		m.cursor, m.offset, m.lineOff = 0, 0, 0
		m.follow = false
	case "enter", "space":
		m.toggle()
	case "right", "l":
		m.open()
	case "left", "h":
		m.closeOrParent()
	case "e":
		m.expandAll()
	case "w":
		m.wrap = !m.wrap
	case "y":
		return m.yankFocused()
	case "Y":
		return m.yankRecordJSON()
	case "/":
		m.filtering = true
		return m.filter.Focus()
	case "n":
		m.jumpMatch(1)
	case "N":
		m.jumpMatch(-1)
	case "f":
		m.layering = true
		m.layerCursor = clamp(m.layerCursor, 0, max(len(m.knownLayers)-1, 0))
	case "F":
		if len(m.layers) > 0 {
			if len(m.rows) > 0 {
				m.follow = false
			}
			clear(m.layers)
			m.dirty = true
		}
	case "esc":
		if m.showHelp {
			m.showHelp = false
			return nil
		}
		if m.query != "" && len(m.rows) > 0 {
			m.follow = false
		}
		m.filter.Reset()
		m.setQuery("")
	case "L":
		m.level = (m.level + 1) % len(record.Levels)
		m.dirty = true
	case "?":
		m.showHelp = !m.showHelp
	case "c":
		m.entries, m.rows, m.lost, m.pendingDivider = nil, nil, nil, nil
		clear(m.entryIdx)
		m.cursor, m.offset, m.records, m.dropped = 0, 0, 0, 0
		m.follow = !m.replay
	}
	return nil
}

func (m *Model) jumpRecord(dir int) {
	if len(m.rows) == 0 {
		return
	}
	m.follow = false
	for i := m.cursor + dir; i >= 0 && i < len(m.rows); i += dir {
		if m.rows[i].kind == rowHeader {
			m.cursor = i
			return
		}
	}
}

func (m *Model) jumpMatch(dir int) {
	if m.query == "" || len(m.rows) == 0 {
		return
	}
	m.follow = false
	n := len(m.rows)
	for step := 1; step <= n; step++ {
		i := (m.cursor + dir*step + n) % n
		r := m.rows[i]
		if r.entry.Divider == "" && strings.Contains(r.entry.search(), m.query) && r.kind == rowHeader {
			m.cursor = i
			return
		}
	}
}

func (m *Model) yankFocused() tea.Cmd {
	r, ok := m.current()
	if !ok || r.entry.Divider != "" {
		return nil
	}
	var text string
	switch r.kind {
	case rowNode, rowScalarLine:
		if r.node != nil {
			text = r.node.CopyText()
		}
	case rowErrorLabel, rowErrorText:
		text = r.entry.Rec.Error
	case rowStackLabel, rowStackLine:
		text = r.entry.Rec.Stack
	case rowCaller:
		text = r.entry.Rec.Caller()
	default:
		text = describeEntry(r.entry)
	}
	if text == "" {
		return nil
	}
	m.notice = "copied"
	return tea.SetClipboard(text)
}

func (m *Model) yankRecordJSON() tea.Cmd {
	r, ok := m.current()
	if !ok || r.entry.Divider != "" {
		return nil
	}
	m.notice = "copied JSON"
	return tea.SetClipboard(string(r.entry.Rec.JSON()))
}

func describeEntry(e *Entry) string {
	rec := e.Rec
	var b strings.Builder
	fmt.Fprintf(&b, "%s [%s] %s: %s",
		rec.Time.Local().Format("15:04:05.000"),
		rec.Layer,
		rec.Level,
		rec.Message,
	)
	if len(rec.Data) > 0 {
		if t := e.tree(); t != nil {
			b.WriteString("\ndata: ")
			b.WriteString(t.PrettyJSON())
		} else {
			b.WriteString("\ndata: ")
			b.Write(rec.Data)
		}
	}
	if rec.Error != "" {
		b.WriteString("\nerror: ")
		b.WriteString(rec.Error)
	}
	if rec.Stack != "" {
		b.WriteByte('\n')
		b.WriteString(strings.TrimRight(rec.Stack, "\n"))
	}
	return b.String()
}

func (m *Model) setQuery(q string) {
	q = strings.ToLower(q)
	if q != m.query {
		m.query = q
		m.dirty = true
	}
}

const wheelStep = 3

// wheel scrolls inside a cursor row taller than the body until its end, then
// moves the viewport by up to [wheelStep] rows. A tall row bounds the step on
// both sides, so it becomes the cursor row and is read through, and the rows
// beside it, which it kept off screen, are never skipped.
func (m *Model) wheel(b tea.MouseButton) {
	dir := 0
	switch b {
	case tea.MouseWheelUp:
		m.follow = false
		if m.lineOff > 0 {
			m.lineOff = max(m.lineOff-wheelStep, 0)
			return
		}
		dir = -1
	case tea.MouseWheelDown:
		if hi := m.maxLineOff(); m.lineOff < hi {
			m.lineOff = min(m.lineOff+wheelStep, hi)
			return
		}
		dir = 1
	default:
		return
	}
	if len(m.rows) == 0 {
		m.offset = 0
		return
	}
	for n := range wheelStep {
		next := m.offset + dir
		if next < 0 || next >= len(m.rows) || (n > 0 && dir < 0 && m.tall(next)) {
			break
		}
		m.offset = next
		if m.tall(next) || (dir > 0 && m.tall(next-1)) {
			break
		}
	}
	from := m.cursor
	m.offset = clamp(m.offset, 0, m.firstFitting(0, len(m.rows)-1))
	m.cursor = clamp(m.cursor, m.offset, m.lastFitting(m.offset))
	m.fromBelow = m.cursor < from
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
	switch {
	case r.kind == rowHeader && r.entry.openable():
		m.follow = false
		if r.entry.Open {
			m.cursor++
			return
		}
		r.entry.Open = true
	case (r.kind == rowNode || r.kind == rowStackLabel) && r.node.Foldable():
		m.follow = false
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
	switch {
	case r.kind == rowHeader && r.entry.Open:
		m.follow = false
		r.entry.Open = false
		m.dirty = true
	case (r.kind == rowNode || r.kind == rowStackLabel) && r.node.Foldable() && r.node.Open:
		m.follow = false
		r.node.Open = false
		m.dirty = true
	case r.parent > 0:
		m.follow = false
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
	if it.Rec.Layer != "" {
		key := strings.ToLower(it.Rec.Layer)
		if _, exists := m.knownLayers[key]; !exists || it.Rec.Color != "" {
			m.knownLayers[key] = layerBadge{
				name:    termsafe.Line(it.Rec.Layer),
				color:   it.Rec.Color,
				onColor: it.Rec.OnColor,
			}
		}
	}
	if it.Restarted && len(m.entries) > 0 {
		m.addEntry(&Entry{Divider: restartedLabel})
	}
	m.addEntry(&Entry{Rec: it.Rec})
}

// addEntry appends e, dropping the oldest entry past [MaxEntries]. Rows are
// patched in place unless a full rebuild is already pending.
func (m *Model) addEntry(e *Entry) {
	m.nextSeq++
	m.entryIdx[e] = m.nextSeq
	m.entries = append(m.entries, e)
	if e.Divider == "" {
		m.records++
	}
	if !m.dirty {
		if e.Divider != "" {
			// Defer rendering the divider until a matching record follows it.
			m.dirty = true
		} else if m.visible(e) {
			if m.pendingDivider != nil {
				m.dirty = true
			} else {
				m.rows = m.appendEntryRows(m.rows, e)
			}
		}
	}
	if len(m.entries) <= MaxEntries {
		return
	}
	old := m.entries[0]
	delete(m.entryIdx, old)
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
	// Never strand a leading orphaned divider after dropping the oldest record.
	for n < len(m.rows) && m.rows[n].kind == rowDivider {
		n++
	}
	if n > 0 {
		clear(m.rows[:n])
		m.rows = m.rows[n:]
		m.cursor -= n
		m.offset -= n
	}
}

func (m *Model) activeFilter() record.Filter {
	return record.Filter{
		MinSeverity: record.Levels[m.level].Severity,
		Layers:      m.layers,
		Query:       m.query,
	}
}

func (m *Model) visible(e *Entry) bool {
	if e.Divider != "" {
		return false
	}
	return m.activeFilter().Match(e.Rec, e.search())
}

func (m *Model) rebuild() {
	var at *anchor
	if !m.follow {
		if cur, ok := m.current(); ok {
			at = &anchor{row: cur, seq: m.entryIdx[cur.entry]}
			for i := m.cursor - 1; i >= 0 && m.rows[i].entry == cur.entry; i-- {
				if m.rows[i].sameSlot(cur) {
					at.nth++
				}
			}
		} else {
			at = m.lost
		}
	}
	m.lost = nil

	rows := make([]row, 0, len(m.rows))
	seenVisible := false
	m.pendingDivider = nil
	for _, e := range m.entries {
		if e.Divider != "" {
			if seenVisible {
				m.pendingDivider = e
			}
			continue
		}
		if !m.visible(e) {
			continue
		}
		if d := m.pendingDivider; d != nil {
			rows = append(rows, row{kind: rowDivider, entry: d, text: d.Divider, index: -1})
			m.pendingDivider = nil
		}
		seenVisible = true
		rows = m.appendEntryRows(rows, e)
	}
	m.rows = rows
	m.dirty = false

	if at != nil && len(m.rows) > 0 {
		m.cursor = m.relocateAnchor(*at)
	} else {
		m.lost = at
	}
}

func (m *Model) relocateAnchor(at anchor) int {
	// 1. Exact (entry, node, kind) match, at its ordinal or the group's last.
	last := -1
	for i, r := range m.rows {
		if r.sameSlot(at.row) {
			if at.nth == 0 {
				return i
			}
			at.nth--
			last = i
		}
	}
	if last >= 0 {
		return last
	}
	// 2. Same entry's header row.
	for i, r := range m.rows {
		if r.entry == at.entry && r.kind == rowHeader {
			return i
		}
	}
	// 3. Nearest surviving header at or after anchor's chronological position.
	for i, r := range m.rows {
		if r.kind == rowHeader && m.entryIdx[r.entry] >= at.seq {
			return i
		}
	}
	return len(m.rows) - 1
}

// settle rebuilds pending rows, applies follow and keeps the cursor on screen.
func (m *Model) settle() {
	if m.dirty {
		m.rebuild()
	}
	if m.follow {
		m.cursor = len(m.rows) - 1
	}
	m.cursor = clamp(m.cursor, 0, max(len(m.rows)-1, 0))
	m.settleLine()
	h := m.bodyHeight()
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if !m.wrap {
		if m.cursor >= m.offset+h {
			m.offset = m.cursor - h + 1
		}
		m.offset = clamp(m.offset, 0, max(len(m.rows)-h, 0))
		return
	}
	// Under soft-wrap, the offset is the earliest row at or after m.offset from
	// which the wrapped lines through m.cursor fit inside h physical lines.
	// Walking back from the cursor wraps at most a screenful of rows, however
	// far the cursor jumped.
	m.offset = clamp(m.offset, 0, max(len(m.rows)-1, 0))
	if m.offset >= m.cursor {
		return
	}
	m.offset = m.firstFitting(m.offset, m.cursor)
}

// settleLine keeps lineOff on the cursor row: a row reached by stepping up
// opens at its last screenful, any other new row at its first line.
// FIXME(P3, strata): rows compare by value, so an offset inside a tall row
// drops to 0 when its row changes shape under the cursor (e on a folded
// sibling) or leaves and returns (a full L cycle, a filter typed and erased).
// FIXME(P3, strata): maxLineOff re-wraps the cursor row on every message; a
// value of about 100 KB under the cursor stalls the viewer while records
// arrive.
func (m *Model) settleLine() {
	cur, _ := m.current()
	if cur != m.lineRow {
		m.lineOff = 0
		if m.fromBelow {
			m.lineOff = m.maxLineOff()
		}
	}
	m.lineRow, m.fromBelow = cur, false
	m.lineOff = clamp(m.lineOff, 0, m.maxLineOff())
}

// tall reports whether row i wraps to more lines than the body holds.
func (m *Model) tall(i int) bool {
	return m.wrap && len(m.wrappedLines(i)) > m.bodyHeight()
}

// maxLineOff is the last valid lineOff for the cursor row.
func (m *Model) maxLineOff() int {
	if !m.wrap || m.cursor < 0 || m.cursor >= len(m.rows) {
		return 0
	}
	return max(len(m.wrappedLines(m.cursor))-m.bodyHeight(), 0)
}

// firstFitting is the earliest row in [floor, last] from which the wrapped
// lines through row last fit in the body; last alone always fits.
func (m *Model) firstFitting(floor, last int) int {
	h := m.bodyHeight()
	top, lines := last, len(m.wrappedLines(last))
	for top > floor {
		above := len(m.wrappedLines(top - 1))
		if lines+above > h {
			break
		}
		lines += above
		top--
	}
	return top
}

// lastFitting is the last row whose wrapped lines, counted from row first,
// fit in the body; first alone always fits.
func (m *Model) lastFitting(first int) int {
	h := m.bodyHeight()
	end, lines := first, len(m.wrappedLines(first))
	for end+1 < len(m.rows) {
		below := len(m.wrappedLines(end + 1))
		if lines+below > h {
			break
		}
		lines += below
		end++
	}
	return end
}

func (m *Model) bodyHeight() int {
	h := m.height - 1 // bottom status bar
	if m.filtering {
		h--
	}
	if m.layering {
		h--
	}
	if m.showHelp {
		h--
	}
	return max(h, 1)
}

func (m *Model) appendEntryRows(rows []row, e *Entry) []row {
	if e.Divider != "" {
		return append(rows, row{kind: rowDivider, entry: e, text: e.Divider, index: -1})
	}
	headerIdx := len(rows)
	rows = append(rows, row{kind: rowHeader, entry: e, index: -1})
	if !e.Open {
		return rows
	}
	child := func(kind rowKind, text string, parent int) row {
		text = termsafe.Line(strings.TrimSuffix(text, "\r"))
		return row{kind: kind, entry: e, text: text, index: -1, parent: len(rows) - parent}
	}
	if caller := e.Rec.Caller(); caller != "" {
		rows = append(rows, child(rowCaller, caller, headerIdx))
	}
	if _, rest, ok := strings.Cut(e.Rec.Message, "\n"); ok {
		for line := range strings.SplitSeq(rest, "\n") {
			rows = append(rows, child(rowText, line, headerIdx))
		}
	}
	if len(e.Rec.Data) > 0 {
		if t := e.tree(); t != nil {
			rows = appendTree(rows, e, t, 0, headerIdx)
		} else {
			rows = append(rows, child(rowText, string(e.Rec.Data), headerIdx))
		}
	}
	if e.Rec.Error != "" {
		labelIdx := len(rows)
		rows = append(rows, child(rowErrorLabel, "Error:", headerIdx))
		for line := range strings.SplitSeq(e.Rec.Error, "\n") {
			rows = append(rows, child(rowErrorText, line, labelIdx))
		}
	}
	if s := e.stackNode(); s != nil {
		labelIdx := len(rows)
		r := child(rowStackLabel, "Stack Trace:", headerIdx)
		r.node = s
		rows = append(rows, r)
		if s.Open {
			for _, line := range s.Children {
				rows = append(rows, child(rowStackLine, line.Literal, labelIdx))
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
		if len(c.Lines) > 1 && c.Open {
			for _, line := range c.Lines {
				rows = append(rows, row{
					kind:   rowScalarLine,
					entry:  e,
					node:   c,
					text:   line,
					depth:  depth + 1,
					index:  -1,
					parent: len(rows) - self,
				})
			}
		}
		rows = appendTree(rows, e, c, depth+1, self)
	}
	return rows
}

// openable reports whether e carries structured body sections beyond its
// one-line message and caller metadata.
func (e *Entry) openable() bool {
	r := e.Rec
	return e.Divider == "" &&
		(len(r.Data) > 0 || r.Error != "" || r.Stack != "" || strings.Contains(r.Message, "\n"))
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

func (e *Entry) preview() string {
	if !e.previewDone {
		e.previewDone = true
		if t := e.tree(); t != nil {
			e.previewText = t.VitalPreview()
		}
	}
	return e.previewText
}

// stackNode is the stack trace as one closed node whose children are its
// lines.
func (e *Entry) stackNode() *tree.Node {
	if e.stack == nil && e.Rec.Stack != "" {
		s := &tree.Node{Key: "Stack Trace", Kind: tree.Array}
		for line := range strings.SplitSeq(strings.TrimRight(e.Rec.Stack, "\n"), "\n") {
			s.Children = append(s.Children, &tree.Node{
				Kind:    tree.Scalar,
				Literal: termsafe.Line(strings.TrimSuffix(line, "\r")),
			})
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
		e.haystack = e.Rec.Haystack()
	}
	return e.haystack
}

// View implements tea.Model.
func (m *Model) View() tea.View {
	var b strings.Builder
	h := m.bodyHeight()
	used := 0
	if len(m.rows) == 0 {
		b.WriteString(m.truncate(dimStyle.Render(termsafe.Line(m.emptyText()))))
		b.WriteByte('\n')
		used = 1
	} else {
		for i := m.offset; i < len(m.rows) && used < h; i++ {
			lines := m.wrappedLines(i)
			if i == m.cursor {
				lines = lines[min(m.lineOff, len(lines)):]
			}
			for _, line := range lines {
				if used >= h {
					break
				}
				b.WriteString(line)
				b.WriteByte('\n')
				used++
			}
		}
	}
	for used < h {
		b.WriteByte('\n')
		used++
	}
	if m.layering {
		b.WriteString(m.truncate(m.layerBarView()))
		b.WriteByte('\n')
	}
	if m.filtering {
		b.WriteString(m.truncate(m.filter.View()))
		b.WriteByte('\n')
	}
	if m.showHelp {
		b.WriteString(m.truncate(dimStyle.Render(helpLine)))
		b.WriteByte('\n')
	}
	b.WriteString(statusStyle.Render(m.padWidth(m.truncate(m.statusText()))))

	v := tea.NewView(b.String())
	v.AltScreen = true
	v.MouseMode = tea.MouseModeCellMotion
	return v
}

const helpLine = " j/k move · [/] record · Enter/l/h fold · e all · w wrap · y/Y copy · / filter · n/N match · L level · f/F layer · G follow · c clear · q quit"

func (m *Model) wrappedLines(i int) []string {
	s := m.renderRow(i)
	if !m.wrap || m.width <= 0 {
		return []string{m.truncate(s)}
	}
	// Each wrapped line must carry its own style: View drops the leading lines
	// of a tall row, and ansi.Wrap opens a style only on the first.
	wrapped := lipgloss.Wrap(s, m.width, "/?&=-_,.:;")
	parts := strings.Split(wrapped, "\n")
	for idx, p := range parts {
		parts[idx] = m.truncate(p)
	}
	return parts
}

func (m *Model) sortedLayers() []layerBadge {
	keys := slices.Sorted(maps.Keys(m.knownLayers))
	out := make([]layerBadge, 0, len(keys))
	for _, k := range keys {
		out = append(out, m.knownLayers[k])
	}
	return out
}

func (m *Model) layerBarView() string {
	list := m.sortedLayers()
	if len(list) == 0 {
		return dimStyle.Render(" layers: none seen yet (Esc to close)")
	}
	var parts []string
	for i, l := range list {
		lower := strings.ToLower(l.name)
		active := len(m.layers) == 0 || m.layers[lower]
		check := " "
		if len(m.layers) > 0 && m.layers[lower] {
			check = "✓"
		}
		prefix := ""
		if i < 9 {
			prefix = fmt.Sprintf("%d:", i+1)
		}
		style := lipgloss.NewStyle()
		if !active {
			style = style.Faint(true)
		} else if l.color != "" {
			style = style.Background(lipgloss.Color(l.color))
			if l.onColor != "" {
				style = style.Foreground(lipgloss.Color(l.onColor))
			}
		}
		chip := fmt.Sprintf("%s[%s]%s", prefix, check, style.Render(" "+l.name+" "))
		if i == m.layerCursor {
			chip = cursorStyle.Render("▸") + chip
		}
		parts = append(parts, chip)
	}
	return " layers: " + strings.Join(parts, " ") + dimStyle.Render("  (←/→ move · 1-9/Space toggle · a all · Enter done)")
}

func (m *Model) truncate(s string) string {
	if m.width <= 0 {
		return s
	}
	return ansi.Truncate(s, m.width, "…")
}

func (m *Model) padWidth(s string) string {
	if m.width <= 0 {
		return s
	}
	w := ansi.StringWidth(s)
	if w >= m.width {
		return s
	}
	return s + strings.Repeat(" ", m.width-w)
}

func (m *Model) emptyText() string {
	switch {
	case m.records > 0:
		return "no records match"
	case m.state == Connected:
		return "connected, no records yet"
	case m.state == Replaying:
		return "no records in " + m.target
	default:
		return "waiting for " + m.target
	}
}

func (m *Model) statusText() string {
	parts := make([]string, 0, 10)
	if m.notice != "" {
		parts = append(parts, m.notice)
	}
	if hi := m.maxLineOff(); hi > 0 {
		h := m.bodyHeight()
		parts = append(parts, fmt.Sprintf("line %d-%d/%d", m.lineOff+1, m.lineOff+h, hi+h))
	}
	parts = append(parts, termsafe.Line(m.stateText()), fmt.Sprintf("%d records", m.records))
	if m.dropped > 0 {
		parts = append(parts, fmt.Sprintf("dropped %d", m.dropped))
	}
	if m.malformed > 0 {
		parts = append(parts, fmt.Sprintf("malformed %d", m.malformed))
	}
	parts = append(parts, "≥"+record.Levels[m.level].Name)
	if len(m.layers) > 0 {
		names := slices.Sorted(maps.Keys(m.layers))
		parts = append(parts, "layers:"+strings.Join(names, ","))
	}
	if m.query != "" && !m.filtering {
		parts = append(parts, "/"+termsafe.Line(m.query))
	}
	if m.wrap {
		parts = append(parts, "wrap")
	}
	if m.follow && !m.replay {
		parts = append(parts, "following")
	}
	if cur, ok := m.current(); ok && cur.entry.Divider == "" {
		if caller := cur.entry.Rec.Caller(); caller != "" {
			parts = append(parts, caller)
		}
	}
	if m.warning != "" {
		parts = append(parts, m.warning)
	}
	if !m.showHelp {
		parts = append(parts, "? help")
	}
	return " " + strings.Join(parts, " · ") + " "
}

func (m *Model) stateText() string {
	switch m.state {
	case Connected:
		return "connected"
	case Disconnected:
		return "disconnected: " + m.stateDetail
	case Replaying:
		return "replay: " + m.stateDetail
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
		return gutter + m.renderHeader(r.entry)
	case rowDivider:
		line := "── " + termsafe.Line(r.text) + " "
		return gutter + dimStyle.Render(line+strings.Repeat("─", max(m.width-ansi.StringWidth(line)-2, 0)))
	case rowCaller:
		return gutter + indent + dimStyle.Render("at "+r.text)
	case rowText:
		return gutter + indent + m.highlight(r.text, lipgloss.NewStyle())
	case rowErrorLabel:
		return gutter + indent + errorStyle.Bold(true).Render(r.text)
	case rowErrorText:
		return gutter + indent + "  " + m.highlight(r.text, errorStyle)
	case rowStackLabel:
		return gutter + indent + marker(r.node) + errorStyle.Render(r.text) + " " + dimStyle.Render(r.node.Summary())
	case rowStackLine:
		return gutter + indent + "    " + m.highlight(r.text, dimStyle)
	case rowNode:
		return gutter + indent + strings.Repeat("  ", r.depth) + marker(r.node) + m.nodeLabel(r) + m.nodeValue(r.node)
	case rowScalarLine:
		return gutter + indent + strings.Repeat("  ", r.depth) + "  " + m.highlight(r.text, stringStyle)
	}
	return gutter
}

func (m *Model) renderHeader(e *Entry) string {
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
	isoTag := ""
	if r.IsolateName != "" && r.IsolateName != "main" {
		isoTag = " " + dimStyle.Render("@"+termsafe.Line(r.IsolateName))
	}
	level := "[" + termsafe.Line(r.Level) + "]"
	if r.LevelColor != "" {
		level = lipgloss.NewStyle().Foreground(lipgloss.Color(r.LevelColor)).Render(level)
	}
	msg := m.highlight(r.FirstLine(), lipgloss.NewStyle())
	tail := ""
	if !e.Open {
		if errText := r.InlineError(); errText != "" {
			tail += "  " + m.highlight("✗ "+errText, errorStyle)
		} else if prev := e.preview(); prev != "" {
			tail += "  " + dimStyle.Render(prev)
		}
	}
	return mark + badge.Render(" "+termsafe.Line(r.Layer)+" ") + isoTag + " " + level + " " +
		dimStyle.Render(r.Time.Local().Format("15:04:05.000")) + " " + msg + tail
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

func (m *Model) nodeLabel(r row) string {
	if r.index >= 0 {
		return dimStyle.Render(fmt.Sprintf("%d: ", r.index))
	}
	return m.highlight(r.node.Key, keyStyle) + ": "
}

func (m *Model) nodeValue(n *tree.Node) string {
	switch {
	case n.Kind != tree.Scalar:
		return dimStyle.Render(n.Summary())
	case len(n.Lines) > 1:
		count := dimStyle.Render(fmt.Sprintf("(%d lines)", len(n.Lines)))
		if n.Open {
			return count
		}
		return m.highlight(`"`+n.Lines[0]+` …"`, stringStyle) + " " + count
	case n.IsString:
		return m.highlight(n.Literal, stringStyle)
	case n.Literal == "true" || n.Literal == "false" || n.Literal == "null":
		return literalStyle.Render(n.Literal)
	default:
		return m.highlight(n.Literal, lipgloss.NewStyle())
	}
}

func (m *Model) highlight(text string, base lipgloss.Style) string {
	if m.query == "" || text == "" {
		return base.Render(text)
	}
	lower := strings.ToLower(text)
	// Fast path when no match or Unicode lowercasing changed byte lengths.
	if !strings.Contains(lower, m.query) || len(lower) != len(text) {
		return base.Render(text)
	}
	hitStyle := base.Inherit(matchStyle)
	var b strings.Builder
	start := 0
	for {
		idx := strings.Index(lower[start:], m.query)
		if idx < 0 {
			break
		}
		pos := start + idx
		if pos > start {
			b.WriteString(base.Render(text[start:pos]))
		}
		end := pos + len(m.query)
		b.WriteString(hitStyle.Render(text[pos:end]))
		start = end
	}
	if start < len(text) {
		b.WriteString(base.Render(text[start:]))
	}
	return b.String()
}

func clamp(v, lo, hi int) int { return min(max(v, lo), hi) }
