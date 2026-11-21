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
		if strings.ContainsFunc(s, controlRune) {
			t.Fatalf("control rune leaked in %q", s)
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
	e32 := strings.Repeat("é", 32)
	for name, tc := range map[string]struct{ in, want string }{
		"keep keys top-level and one level down": {
			in:   `{"headers":{"x":"1"},"status":200,"body":{"id":42,"name":"Jane","extra":[1,2]},"duration_ms":12}`,
			want: "status: 200 · id: 42 · name: Jane · 4 keys",
		},
		"three hits at most":              {in: `{"id":1,"name":"a","status":"ok","code":7}`, want: "id: 1 · name: a · status: ok · 4 keys"},
		"value of 32 runes kept whole":    {in: `{"name":"` + e32 + `"}`, want: "name: " + e32 + " · 1 key"},
		"multibyte value clipped by rune": {in: `{"name":"` + e32 + `ééé"}`, want: "name: " + e32 + "… · 1 key"},
		"array counts its items":          {in: `[1,2,3]`, want: "3 items"},
		"long scalar clipped":             {in: `"abcdefghijklmnopqrstuvwxyz0123456789"`, want: `"abcdefghijklmnopqrstuvwxyz01234…`},
	} {
		t.Run(name, func(t *testing.T) {
			if got := mustParse(t, tc.in).VitalPreview(); got != tc.want {
				t.Errorf("VitalPreview() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestCopyTextOnContainerIsIndentedJSONInWireOrder(t *testing.T) {
	root := mustParse(t, `{"z":1.0,"a":[1e3,{},{"k":null}],"s":"<&>\nx"}`)
	want := `{
  "z": 1.0,
  "a": [
    1e3,
    {},
    {
      "k": null
    }
  ],
  "s": "<&>\nx"
}`
	if got := root.CopyText(); got != want {
		t.Errorf("CopyText() =\n%s\nwant\n%s", got, want)
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
			for _, s := range append([]string{cur.Key, cur.Literal, cur.Summary()}, cur.Lines...) {
				if strings.ContainsFunc(s, controlRune) {
					t.Fatalf("unsafe rune in %q", s)
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

// controlRune is the test's own oracle for terminal-unsafe runes, independent
// of termsafe.IsControl: C0, DEL and C1.
func controlRune(r rune) bool { return r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) }
