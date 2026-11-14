package termsafe

import "testing"

func TestLineAndInline(t *testing.T) {
	t.Parallel()
	for name, tc := range map[string]struct{ in, line, inline string }{
		"plain":          {"GET /users/42 ✓", "GET /users/42 ✓", "GET /users/42 ✓"},
		"esc sequence":   {"a\x1b[2Jb", `a\x1b[2Jb`, `a\x1b[2Jb`},
		"del":            {"a\x7fb", `a\x7fb`, `a\x7fb`},
		"c1 csi":         {"a\u009b2Jb", `a\x9b2Jb`, `a\x9b2Jb`},
		"invalid byte":   {"a\x9b2Jb", `a\x9b2Jb`, `a\x9b2Jb`},
		"line separator": {"a\u2028b\u2029c", "a\\u2028b\\u2029c", "a\\u2028b\\u2029c"},
		"tab":            {"a\tb", "a b", `a\tb`},
		"newline and cr": {"a\r\nb", `a\x0d\x0ab`, `a\r\nb`},
		"literal fffd":   {"a�b", "a�b", "a�b"},
		"truncated utf8": {"a\xe2\x9c", `a\xe2\x9c`, `a\xe2\x9c`},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if got := Line(tc.in); got != tc.line {
				t.Errorf("Line(%q) = %q, want %q", tc.in, got, tc.line)
			}
			if got := Inline(tc.in); got != tc.inline {
				t.Errorf("Inline(%q) = %q, want %q", tc.in, got, tc.inline)
			}
		})
	}
}

func FuzzEscapedTextHasNoControls(f *testing.F) {
	for _, s := range []string{"", "a\x1b[31mb", "\u009b\u2028\t\r\n", "\xff\xfe"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		for _, out := range []string{Line(s), Inline(s)} {
			for _, c := range out {
				if IsControl(c) || c == '�' && !containsFFFD(s) {
					t.Fatalf("escape(%q) leaked %U in %q", s, c, out)
				}
			}
		}
	})
}

func containsFFFD(s string) bool {
	for _, c := range s {
		if c == '�' {
			return true
		}
	}
	return false
}
