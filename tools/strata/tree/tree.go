// Package tree parses JSON into a foldable tree that keeps object key order
// and scalar literals as sent while sanitizing terminal control bytes.
package tree

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/esenmx/stratalog/tools/strata/termsafe"
)

// Kind classifies a [Node].
type Kind int

// Node kinds.
const (
	Object Kind = iota
	Array
	Scalar
)

// defaultKeepKeys mirrors stratalog's ElisionConfig.keepKeys:
// vital identifier/status keys surfaced on collapsed rows.
var defaultKeepKeys = map[string]bool{
	"id":     true,
	"uuid":   true,
	"guid":   true,
	"name":   true,
	"slug":   true,
	"status": true,
	"state":  true,
	"code":   true,
	"type":   true,
	"kind":   true,
}

// Node is one JSON value. Key is its terminal-safe object key (RawKey holds
// the original decoded key); array elements and the root have none.
type Node struct {
	Key      string
	RawKey   string
	Kind     Kind
	Literal  string   // Scalar only: terminal-safe JSON literal, strings quoted
	Raw      string   // String scalar only: decoded string value
	Lines    []string // Multi-line string scalar only: sanitized lines (len > 1)
	IsString bool
	Children []*Node
	Open     bool
}

// Row is one visible line of a tree: a node at an indentation depth.
type Row struct {
	Node  *Node
	Depth int
}

// Parse builds the tree for raw. The root is open; every node below starts
// closed.
func Parse(raw json.RawMessage) (*Node, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	root, err := parseValue(dec, "")
	if err != nil {
		return nil, fmt.Errorf("tree: %w", err)
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("tree: trailing data after JSON value")
	}
	root.Open = true
	return root, nil
}

func parseValue(dec *json.Decoder, rawKey string) (*Node, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	safeKey := termsafe.Inline(rawKey)
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '{':
			return parseObject(dec, safeKey, rawKey)
		case '[':
			return parseArray(dec, safeKey, rawKey)
		default:
			return nil, fmt.Errorf("unexpected %q", t)
		}
	case string:
		lit, err := quote(t)
		if err != nil {
			return nil, err
		}
		var lines []string
		trimmed := strings.TrimSuffix(t, "\n")
		if strings.Contains(trimmed, "\n") {
			rawLines := strings.Split(trimmed, "\n")
			lines = make([]string, len(rawLines))
			for i, l := range rawLines {
				lines[i] = termsafe.Line(strings.TrimSuffix(l, "\r"))
			}
		}
		return &Node{
			Key:      safeKey,
			RawKey:   rawKey,
			Kind:     Scalar,
			Literal:  lit,
			Raw:      t,
			Lines:    lines,
			IsString: true,
		}, nil
	case json.Number:
		return &Node{Key: safeKey, RawKey: rawKey, Kind: Scalar, Literal: termsafe.Inline(t.String())}, nil
	case bool:
		return &Node{Key: safeKey, RawKey: rawKey, Kind: Scalar, Literal: strconv.FormatBool(t)}, nil
	case nil:
		return &Node{Key: safeKey, RawKey: rawKey, Kind: Scalar, Literal: "null"}, nil
	default:
		return nil, fmt.Errorf("unexpected token %v", tok)
	}
}

func parseObject(dec *json.Decoder, safeKey, rawKey string) (*Node, error) {
	n := &Node{Key: safeKey, RawKey: rawKey, Kind: Object}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return nil, err
		}
		k, ok := tok.(string)
		if !ok {
			return nil, fmt.Errorf("object key %v is not a string", tok)
		}
		child, err := parseValue(dec, k)
		if err != nil {
			return nil, err
		}
		n.Children = append(n.Children, child)
	}
	if _, err := dec.Token(); err != nil { // '}'
		return nil, err
	}
	return n, nil
}

func parseArray(dec *json.Decoder, safeKey, rawKey string) (*Node, error) {
	n := &Node{Key: safeKey, RawKey: rawKey, Kind: Array}
	for dec.More() {
		child, err := parseValue(dec, "")
		if err != nil {
			return nil, err
		}
		n.Children = append(n.Children, child)
	}
	if _, err := dec.Token(); err != nil { // ']'
		return nil, err
	}
	return n, nil
}

// quote re-encodes s as a JSON string, leaving <, > and & unescaped while
// escaping DEL, C1 controls, and Unicode line separators as \uXXXX so the
// literal is both valid JSON and safe to write to a terminal.
func quote(s string) (string, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(s); err != nil {
		return "", err
	}
	encoded := string(bytes.TrimSuffix(b.Bytes(), []byte("\n")))
	if !strings.ContainsFunc(encoded, termsafe.IsControl) {
		return encoded, nil
	}
	var out strings.Builder
	out.Grow(len(encoded) + 8)
	for _, c := range encoded {
		if termsafe.IsControl(c) {
			fmt.Fprintf(&out, `\u%04x`, c)
		} else {
			out.WriteRune(c)
		}
	}
	return out.String(), nil
}

// Rows lists the visible descendants of n depth-first: its children at
// depth 0 when n is open, and recursively the children of every open node.
// n itself is not a row.
func (n *Node) Rows() []Row {
	var rows []Row
	n.appendRows(&rows, 0)
	return rows
}

func (n *Node) appendRows(rows *[]Row, depth int) {
	if !n.Open {
		return
	}
	for _, c := range n.Children {
		*rows = append(*rows, Row{Node: c, Depth: depth})
		c.appendRows(rows, depth+1)
	}
}

// Foldable reports whether n has children or multi-line string content to open.
func (n *Node) Foldable() bool {
	return (n.Kind != Scalar && len(n.Children) > 0) || len(n.Lines) > 1
}

// Summary is n's value as one closed line: `{…} N keys`, `[…] N items`,
// `{}`/`[]` when empty, or a scalar's literal.
func (n *Node) Summary() string {
	switch n.Kind {
	case Object:
		if len(n.Children) == 0 {
			return "{}"
		}
		return "{…} " + count(len(n.Children), "key", "keys")
	case Array:
		if len(n.Children) == 0 {
			return "[]"
		}
		return "[…] " + count(len(n.Children), "item", "items")
	default:
		return n.Literal
	}
}

// SetOpenAll opens or closes n and every node below it.
func (n *Node) SetOpenAll(open bool) {
	n.Open = open
	for _, c := range n.Children {
		c.SetOpenAll(open)
	}
}

// PrettyJSON formats n and its descendants as 2-space-indented valid JSON,
// preserving object key order and exact number literals.
func (n *Node) PrettyJSON() string {
	var b strings.Builder
	n.writeJSON(&b, 0)
	return b.String()
}

func (n *Node) writeJSON(b *strings.Builder, depth int) {
	switch n.Kind {
	case Object:
		if len(n.Children) == 0 {
			b.WriteString("{}")
			return
		}
		b.WriteString("{\n")
		indent := strings.Repeat("  ", depth+1)
		for i, c := range n.Children {
			b.WriteString(indent)
			k, _ := quote(c.RawKey)
			b.WriteString(k)
			b.WriteString(": ")
			c.writeJSON(b, depth+1)
			if i+1 < len(n.Children) {
				b.WriteByte(',')
			}
			b.WriteByte('\n')
		}
		b.WriteString(strings.Repeat("  ", depth))
		b.WriteByte('}')
	case Array:
		if len(n.Children) == 0 {
			b.WriteString("[]")
			return
		}
		b.WriteString("[\n")
		indent := strings.Repeat("  ", depth+1)
		for i, c := range n.Children {
			b.WriteString(indent)
			c.writeJSON(b, depth+1)
			if i+1 < len(n.Children) {
				b.WriteByte(',')
			}
			b.WriteByte('\n')
		}
		b.WriteString(strings.Repeat("  ", depth))
		b.WriteByte(']')
	default:
		if n.IsString {
			s, _ := quote(n.Raw)
			b.WriteString(s)
		} else {
			b.WriteString(n.Literal)
		}
	}
}

// CopyText returns the clipboard payload for n: unquoted raw text for string
// scalars, the literal for other scalars, and indented JSON for containers.
func (n *Node) CopyText() string {
	if n.Kind == Scalar {
		if n.IsString {
			return n.Raw
		}
		return n.Literal
	}
	return n.PrettyJSON()
}

// VitalPreview builds a compact one-line summary for a collapsed row: up to 3
// keepKeys hits (top-level or one object level down) followed by the
// top-level field/item count.
func (n *Node) VitalPreview() string {
	switch n.Kind {
	case Object:
		if len(n.Children) == 0 {
			return ""
		}
		const maxHits = 3
		const maxChars = 32
		var parts []string
		addHit := func(c *Node) {
			if len(parts) >= maxHits || !defaultKeepKeys[c.RawKey] {
				return
			}
			var val string
			switch {
			case c.Kind != Scalar:
				val = c.Summary()
			case c.IsString:
				val = clipRunes(termsafe.Inline(c.Raw), maxChars)
			default:
				val = clipRunes(c.Literal, maxChars)
			}
			parts = append(parts, c.Key+": "+val)
		}
		for _, c := range n.Children {
			addHit(c)
			if c.Kind == Object {
				for _, gc := range c.Children {
					addHit(gc)
				}
			}
			if len(parts) >= maxHits {
				break
			}
		}
		parts = append(parts, count(len(n.Children), "key", "keys"))
		return strings.Join(parts, " · ")
	case Array:
		if len(n.Children) == 0 {
			return ""
		}
		return count(len(n.Children), "item", "items")
	default:
		return clipRunes(n.Literal, 32)
	}
}

func clipRunes(s string, limit int) string {
	if utf8.RuneCountInString(s) <= limit {
		return s
	}
	var b strings.Builder
	i := 0
	for _, r := range s {
		if i >= limit {
			break
		}
		b.WriteRune(r)
		i++
	}
	b.WriteRune('…')
	return b.String()
}

func count(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return strconv.Itoa(n) + " " + many
}
