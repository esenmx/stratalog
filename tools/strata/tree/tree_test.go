package tree

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
)

func mustParse(t *testing.T, raw string) *Node {
	t.Helper()
	n, err := Parse(json.RawMessage(raw))
	if err != nil {
		t.Fatalf("Parse(%s): %v", raw, err)
	}
	return n
}

// rowText renders rows as "depth:key=summary" for compact comparison.
func rowText(rows []Row) []string {
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, strings.Repeat(" ", r.Depth)+r.Node.Key+"="+r.Node.Summary())
	}
	return out
}

func TestParseKeepsKeyOrder(t *testing.T) {
	root := mustParse(t, `{"zeta":1,"alpha":2,"mid":3,"beta":4}`)

	keys := make([]string, 0, len(root.Children))
	for _, c := range root.Children {
		keys = append(keys, c.Key)
	}
	if want := []string{"zeta", "alpha", "mid", "beta"}; !slices.Equal(keys, want) {
		t.Errorf("keys = %v, want %v", keys, want)
	}
}

func TestScalarLiterals(t *testing.T) {
	for name, tc := range map[string]struct {
		in, want string
	}{
		"float keeps trailing zero": {in: `1.0`, want: `1.0`},
		"exponent verbatim":         {in: `1e3`, want: `1e3`},
		"int beyond float64":        {in: `12345678901234567890123`, want: `12345678901234567890123`},
		"negative":                  {in: `-0.50`, want: `-0.50`},
		"string":                    {in: `"Jane"`, want: `"Jane"`},
		"string escapes kept JSON":  {in: `"a\"b\n<&>"`, want: `"a\"b\n<&>"`},
		"unicode escape decoded":    {in: `"é"`, want: `"é"`},
		"true":                      {in: `true`, want: `true`},
		"null":                      {in: `null`, want: `null`},
	} {
		t.Run(name, func(t *testing.T) {
			root := mustParse(t, `{"k":`+tc.in+`}`)
			got := root.Children[0]
			if got.Kind != Scalar || got.Literal != tc.want {
				t.Errorf("Literal = %q (kind %d), want %q", got.Literal, got.Kind, tc.want)
			}
		})
	}
}

func TestRowsFollowOpenNodes(t *testing.T) {
	root := mustParse(t, `{"status":200,"body":{"id":42,"tags":["a",["b","c"]]},"empty":{},"none":[]}`)

	if got, want := rowText(root.Rows()), []string{
		"status=200",
		"body={…} 2 keys",
		"empty={}",
		"none=[]",
	}; !slices.Equal(got, want) {
		t.Errorf("closed rows = %q\nwant %q", got, want)
	}

	body := root.Children[1]
	body.Open = true
	tags := body.Children[1]
	tags.Open = true
	tags.Children[1].Open = true
	if got, want := rowText(root.Rows()), []string{
		"status=200",
		"body={…} 2 keys",
		" id=42",
		" tags=[…] 2 items",
		`  ="a"`,
		"  =[…] 2 items",
		`   ="b"`,
		`   ="c"`,
		"empty={}",
		"none=[]",
	}; !slices.Equal(got, want) {
		t.Errorf("open rows = %q\nwant %q", got, want)
	}

	body.Open = false
	if got := len(root.Rows()); got != 4 {
		t.Errorf("rows after closing body = %d, want 4 (children of closed nodes hidden)", got)
	}
}

func TestSetOpenAll(t *testing.T) {
	root := mustParse(t, `{"a":{"b":{"c":1}},"d":[1,[2]]}`)

	root.SetOpenAll(true)
	if got := len(root.Rows()); got != 7 {
		t.Errorf("rows after SetOpenAll(true) = %d, want 7", got)
	}

	root.SetOpenAll(false)
	if got := len(root.Rows()); got != 0 {
		t.Errorf("rows after SetOpenAll(false) = %d, want 0", got)
	}
}

func TestParseRootIsOpenChildrenClosed(t *testing.T) {
	root := mustParse(t, `{"a":{"b":1}}`)
	if !root.Open || root.Children[0].Open {
		t.Errorf("root.Open = %v, child.Open = %v; want true, false", root.Open, root.Children[0].Open)
	}
}

func TestSummary(t *testing.T) {
	for name, tc := range map[string]struct {
		in, want string
	}{
		"one key":    {in: `{"a":1}`, want: "{…} 1 key"},
		"keys":       {in: `{"a":1,"b":2}`, want: "{…} 2 keys"},
		"one item":   {in: `[1]`, want: "[…] 1 item"},
		"items":      {in: `[1,2,3]`, want: "[…] 3 items"},
		"empty obj":  {in: `{}`, want: "{}"},
		"empty list": {in: `[]`, want: "[]"},
	} {
		t.Run(name, func(t *testing.T) {
			if got := mustParse(t, tc.in).Summary(); got != tc.want {
				t.Errorf("Summary() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestParseRejectsMalformed(t *testing.T) {
	for name, in := range map[string]string{
		"truncated":     `{"a":`,
		"trailing data": `{} {}`,
		"empty":         ``,
		"bad close":     `{"a":1]`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := Parse(json.RawMessage(in)); err == nil {
				t.Errorf("Parse(%q) succeeded, want error", in)
			}
		})
	}
}

func TestSanitizesControlCharsInKeysAndLiterals(t *testing.T) {
	root := mustParse(t, "{\"a\\u001b[2J\\nb\": \"x\u009b2J\u007fy\"}")
	child := root.Children[0]
	for _, s := range []string{child.Key, child.Literal} {
		for _, c := range s {
			if c < 0x20 || c == 0x7f || (c >= 0x80 && c < 0xa0) {
				t.Fatalf("control rune %U leaked in %q", c, s)
			}
		}
	}
	// CopyText on the root still preserves valid JSON with original key.
	var decoded map[string]string
	if err := json.Unmarshal([]byte(root.PrettyJSON()), &decoded); err != nil {
		t.Fatalf("PrettyJSON invalid: %v\n%s", err, root.PrettyJSON())
	}
	if _, ok := decoded["a\x1b[2J\nb"]; !ok {
		t.Errorf("PrettyJSON lost original key: %v", decoded)
	}
}

func TestMultiLineScalarIsFoldableAndCopiesRaw(t *testing.T) {
	root := mustParse(t, `{"sql":"SELECT *\nFROM users\nWHERE id = 1","id":42}`)
	sqlNode := root.Children[0]
	if !sqlNode.Foldable() || len(sqlNode.Lines) != 3 {
		t.Fatalf("sqlNode Foldable=%v len(Lines)=%d, want true, 3", sqlNode.Foldable(), len(sqlNode.Lines))
	}
	if got := sqlNode.CopyText(); got != "SELECT *\nFROM users\nWHERE id = 1" {
		t.Errorf("CopyText() = %q", got)
	}
	if got := root.Children[1].CopyText(); got != "42" {
		t.Errorf("number CopyText() = %q, want 42", got)
	}
}

func TestVitalPreview(t *testing.T) {
	root := mustParse(t, `{"headers":{"x":"1"},"status":200,"body":{"id":42,"name":"Jane","extra":[1,2]},"duration_ms":12}`)
	got := root.VitalPreview()
	want := "status: 200 · id: 42 · name: Jane · 4 keys"
	if got != want {
		t.Errorf("VitalPreview() = %q, want %q", got, want)
	}
}

func FuzzParseSafetyAndRoundTrip(f *testing.F) {
	f.Add([]byte(`{"status":200,"body":{"\u001b[2J":"line1\nline2\u009b"}}`))
	f.Add([]byte(`[1, 1.0, 1e9, true, false, null, "a<&>b", {}, []]`))
	f.Fuzz(func(t *testing.T, raw []byte) {
		n, err := Parse(raw)
		if err != nil {
			return
		}
		var checkNode func(*Node)
		checkNode = func(cur *Node) {
			for _, s := range []string{cur.Key, cur.Literal, cur.Summary()} {
				for _, c := range s {
					if c < 0x20 || c == 0x7f || (c >= 0x80 && c < 0xa0) {
						t.Fatalf("unsafe rune %U in %q", c, s)
					}
				}
			}
			for _, line := range cur.Lines {
				for _, c := range line {
					if c < 0x20 || c == 0x7f || (c >= 0x80 && c < 0xa0) {
						t.Fatalf("unsafe rune %U in line %q", c, line)
					}
				}
			}
			for _, c := range cur.Children {
				checkNode(c)
			}
		}
		checkNode(n)
		if !json.Valid([]byte(n.PrettyJSON())) {
			t.Fatalf("PrettyJSON produced invalid JSON:\n%s", n.PrettyJSON())
		}
	})
}
