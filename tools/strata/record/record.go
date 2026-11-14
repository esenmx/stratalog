// Package record decodes, filters, and formats stratalog record
// schema v1, the JSON posted by the Dart VmStreamWriter on the "stratalog" VM
// service stream (and written to NDJSON capture files).
package record

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/esenmx/stratalog/tools/strata/termsafe"
)

// SchemaVersion is the newest record schema this build understands.
const SchemaVersion = 1

// LevelSpec pairs a canonical chirp level name with its minimum severity.
type LevelSpec struct {
	Name     string
	Severity int
}

// Levels lists chirp's standard log levels in ascending severity order.
var Levels = []LevelSpec{
	{"trace", 0},
	{"debug", 100},
	{"info", 200},
	{"notice", 300},
	{"success", 310},
	{"warning", 400},
	{"error", 500},
	{"critical", 600},
	{"wtf", 1000},
}

// ParseLevel resolves a case-insensitive level name to its index in [Levels].
func ParseLevel(name string) (int, bool) {
	needle := strings.ToLower(strings.TrimSpace(name))
	for i, l := range Levels {
		if l.Name == needle {
			return i, true
		}
	}
	return 0, false
}

// Filter selects records by minimum severity, layer set, and substring query.
type Filter struct {
	MinSeverity int
	Layers      map[string]bool // lowercased layer names; empty accepts all
	Query       string          // lowercased substring; empty accepts all
}

// Match reports whether r (with precomputed lowercased haystack) passes f.
func (f Filter) Match(r Record, haystack string) bool {
	if r.Severity < f.MinSeverity {
		return false
	}
	if len(f.Layers) > 0 && !f.Layers[strings.ToLower(r.Layer)] {
		return false
	}
	if f.Query == "" {
		return true
	}
	if haystack == "" {
		haystack = r.Haystack()
	}
	return strings.Contains(haystack, f.Query)
}

// Record is one stratalog log record. Optional fields are zero when the
// record omits them.
type Record struct {
	V          int             `json:"v"`
	Seq        int64           `json:"seq"`
	Time       time.Time       `json:"time"`
	Level      string          `json:"level"`
	Severity   int             `json:"severity"`
	Layer      string          `json:"layer"`
	Color      string          `json:"color"`
	OnColor    string          `json:"onColor"`
	LevelColor string          `json:"levelColor,omitempty"`
	Message    string          `json:"message"`
	File       string          `json:"file,omitempty"`
	Line       int             `json:"line,omitempty"`
	Method     string          `json:"method,omitempty"`
	Data       json.RawMessage `json:"data,omitempty"`
	Error      string          `json:"error,omitempty"`
	Stack      string          `json:"stack,omitempty"`

	// IsolateID and IsolateName identify the posting isolate. IsolateName is
	// persisted as "isolate" when non-empty and not "main" so NDJSON captures
	// preserve worker-isolate origin.
	IsolateID   string `json:"-"`
	IsolateName string `json:"isolate,omitempty"`
}

// ErrNotRecord reports JSON that decodes but carries no schema version.
var ErrNotRecord = errors.New("record: missing schema version")

// Decode parses one record. A record newer than [SchemaVersion] still decodes
// its known fields; callers compare V to warn.
func Decode(b []byte) (Record, error) {
	var r Record
	if err := json.Unmarshal(b, &r); err != nil {
		return Record{}, fmt.Errorf("record: %w", err)
	}
	if r.V < 1 {
		return Record{}, ErrNotRecord
	}
	return r, nil
}

// Caller formats `file:line method` (omitting `:0` when Line <= 0), sanitized
// via [termsafe.Line], or "" when File is empty.
func (r Record) Caller() string {
	if r.File == "" {
		return ""
	}
	s := termsafe.Line(r.File)
	if r.Line > 0 {
		s = fmt.Sprintf("%s:%d", s, r.Line)
	}
	if r.Method != "" {
		s += " " + termsafe.Line(r.Method)
	}
	return s
}

// Haystack returns the lowercased searchable text across all record fields.
func (r Record) Haystack() string {
	return strings.ToLower(strings.Join([]string{
		r.Layer,
		r.IsolateName,
		r.Level,
		r.Message,
		r.Caller(),
		string(r.Data),
		r.Error,
		r.Stack,
	}, "\n"))
}

// FirstLine is the message's first line, [termsafe.Line], suffixed " …" when
// more follow.
func (r Record) FirstLine() string {
	first, _, multi := strings.Cut(r.Message, "\n")
	first = termsafe.Line(strings.TrimSuffix(first, "\r"))
	if multi {
		return first + " …"
	}
	return first
}

// InlineError formats r.Error onto a single terminal-safe line while keeping
// all lines of multi-line exceptions visible via ` \n ` separators.
func (r Record) InlineError() string {
	if r.Error == "" {
		return ""
	}
	norm := strings.ReplaceAll(r.Error, "\r\n", "\n")
	norm = strings.TrimRight(norm, "\n")
	parts := strings.Split(norm, "\n")
	for i, p := range parts {
		parts[i] = termsafe.Line(strings.TrimSuffix(p, "\r"))
	}
	return strings.Join(parts, ` \n `)
}

// Plain renders `HH:MM:SS.mmm Layer[@isolate] [level] message {data} ✗ error`
// in local time, single-line and without ANSI or terminal control characters.
func (r Record) Plain() string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s %s", r.Time.Local().Format("15:04:05.000"), termsafe.Line(r.Layer))
	if r.IsolateName != "" && r.IsolateName != "main" {
		fmt.Fprintf(&b, "@%s", termsafe.Line(r.IsolateName))
	}
	fmt.Fprintf(&b, " [%s] %s", termsafe.Line(r.Level), r.FirstLine())
	if len(r.Data) > 0 {
		var data bytes.Buffer
		if err := json.Compact(&data, r.Data); err == nil {
			b.WriteByte(' ')
			b.WriteString(termsafe.Line(data.String()))
		}
	}
	if errText := r.InlineError(); errText != "" {
		b.WriteString(" ✗ ")
		b.WriteString(errText)
	}
	return b.String()
}

// JSON encodes r as one compact NDJSON line (without a trailing newline),
// keeping Data's wire key order and leaving <, > and & unescaped.
func (r Record) JSON() []byte {
	out := r
	if out.IsolateName == "main" {
		out.IsolateName = ""
	}
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(out)
	return bytes.TrimSuffix(b.Bytes(), []byte("\n"))
}
