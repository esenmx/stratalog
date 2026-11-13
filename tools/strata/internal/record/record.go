// Package record decodes stratalog record schema v1, the JSON posted by the
// Dart VmStreamWriter on the "stratalog" VM service stream.
package record

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// SchemaVersion is the newest record schema this build understands.
const SchemaVersion = 1

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

	// IsolateID names the isolate that posted the record; set by the VM
	// service client, never part of the wire record.
	IsolateID string `json:"-"`
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

// FirstLine is the message's first line, suffixed " …" when more follow.
func (r Record) FirstLine() string {
	first, _, multi := strings.Cut(r.Message, "\n")
	if multi {
		return first + " …"
	}
	return first
}

// Plain renders `HH:MM:SS.mmm Layer [level] message {data}` in local time,
// without ANSI.
func (r Record) Plain() string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s %s [%s] %s", r.Time.Local().Format("15:04:05.000"), r.Layer, r.Level, r.FirstLine())
	if len(r.Data) > 0 {
		var data bytes.Buffer
		if err := json.Compact(&data, r.Data); err == nil {
			b.WriteByte(' ')
			b.Write(data.Bytes())
		}
	}
	return b.String()
}
