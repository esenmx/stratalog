// Package termsafe makes untrusted record text safe to write to a terminal:
// control characters and invalid UTF-8 become visible escapes, so a record
// can neither drive the terminal nor break the line it is drawn on.
package termsafe

import (
	"fmt"
	"strings"
	"unicode/utf8"
)

// IsControl reports whether c must never reach a terminal raw: C0 (including
// tab, LF, CR and ESC), DEL, C1, and the Unicode line and paragraph
// separators.
func IsControl(c rune) bool {
	return c < 0x20 || c == 0x7f || (c >= 0x80 && c < 0xa0) || c == '\u2028' || c == '\u2029'
}

// Line makes one line of display text safe: a tab becomes a space, and every
// other control character or invalid UTF-8 byte becomes a `\xNN` or `\uNNNN`
// escape.
func Line(s string) string { return escape(s, false) }

// Inline is [Line] for text whose whitespace is content (object keys,
// literals): tab, LF and CR show as `\t`, `\n` and `\r` instead.
func Inline(s string) string { return escape(s, true) }

func escape(s string, inline bool) string {
	if utf8.ValidString(s) && !strings.ContainsFunc(s, IsControl) {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); {
		c, w := utf8.DecodeRuneInString(s[i:])
		switch {
		case c == utf8.RuneError && w == 1:
			fmt.Fprintf(&b, `\x%02x`, s[i])
		case inline && c == '\t':
			b.WriteString(`\t`)
		case inline && c == '\n':
			b.WriteString(`\n`)
		case inline && c == '\r':
			b.WriteString(`\r`)
		case c == '\t':
			b.WriteByte(' ')
		case c <= 0xff && IsControl(c):
			fmt.Fprintf(&b, `\x%02x`, c)
		case IsControl(c):
			fmt.Fprintf(&b, `\u%04x`, c)
		default:
			b.WriteRune(c)
		}
		i += w
	}
	return b.String()
}
