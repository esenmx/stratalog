// Package tree parses JSON into a foldable tree that keeps object key order
// and scalar literals exactly as sent.
package tree

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
)

// Kind classifies a [Node].
type Kind int

// Node kinds.
const (
	Object Kind = iota
	Array
	Scalar
)

// Node is one JSON value. Key is its object key; array elements and the
// root have none.
type Node struct {
	Key      string
	Kind     Kind
	Literal  string // Scalar only: the JSON text, strings quoted
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

func parseValue(dec *json.Decoder, key string) (*Node, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '{':
			return parseObject(dec, key)
		case '[':
			return parseArray(dec, key)
		default:
			return nil, fmt.Errorf("unexpected %q", t)
		}
	case string:
		lit, err := quote(t)
		if err != nil {
			return nil, err
		}
		return &Node{Key: key, Kind: Scalar, Literal: lit}, nil
	case json.Number:
		return &Node{Key: key, Kind: Scalar, Literal: t.String()}, nil
	case bool:
		return &Node{Key: key, Kind: Scalar, Literal: strconv.FormatBool(t)}, nil
	case nil:
		return &Node{Key: key, Kind: Scalar, Literal: "null"}, nil
	default:
		return nil, fmt.Errorf("unexpected token %v", tok)
	}
}

func parseObject(dec *json.Decoder, key string) (*Node, error) {
	n := &Node{Key: key, Kind: Object}
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

func parseArray(dec *json.Decoder, key string) (*Node, error) {
	n := &Node{Key: key, Kind: Array}
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

// quote re-encodes s as a JSON string, leaving <, > and & unescaped.
func quote(s string) (string, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(s); err != nil {
		return "", err
	}
	return string(bytes.TrimSuffix(b.Bytes(), []byte("\n"))), nil
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

// Foldable reports whether n has children to open.
func (n *Node) Foldable() bool { return n.Kind != Scalar && len(n.Children) > 0 }

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

func count(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return strconv.Itoa(n) + " " + many
}
