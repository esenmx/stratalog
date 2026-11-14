package record

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/esenmx/stratalog/tools/strata/termsafe"
)

// The Dart contract test asserts VmStreamWriter produces this fixture; this
// one asserts strata decodes it.
func TestDecodeContractFixture(t *testing.T) {
	b, err := os.ReadFile("../testdata/record_v1.json")
	if err != nil {
		t.Fatal(err)
	}

	r, err := Decode(b)
	if err != nil {
		t.Fatal(err)
	}

	var data bytes.Buffer
	if err := json.Compact(&data, r.Data); err != nil {
		t.Fatal(err)
	}
	// Key order as sent: strata renders payloads in wire order.
	const wantData = `{"status":200,"body":{"id":42,"name":"Jane","tags":["a","b"]},"duration_ms":12}`
	if data.String() != wantData {
		t.Errorf("Data = %s, want %s", data.String(), wantData)
	}

	wantTime := time.Date(2026, 1, 2, 3, 4, 5, 678_000_000, time.UTC)
	if !r.Time.Equal(wantTime) {
		t.Errorf("Time = %v, want %v", r.Time, wantTime)
	}

	r.Data, r.Time = nil, time.Time{}
	want := Record{
		V:        1,
		Seq:      1,
		Level:    "info",
		Severity: 200,
		Layer:    "Network",
		Color:    "#875fff",
		OnColor:  "#ffffff",
		Message:  "← 200 GET https://api.example.com/users/42",
	}
	if !reflect.DeepEqual(r, want) {
		t.Errorf("Decode = %+v\nwant     %+v", r, want)
	}
}

func TestDecodeErrors(t *testing.T) {
	for name, tc := range map[string]struct {
		in   string
		want error
	}{
		"no version":    {in: `{"seq":1}`, want: ErrNotRecord},
		"not an object": {in: `[1]`},
		"bad json":      {in: `{"v":`},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := Decode([]byte(tc.in))
			if err == nil {
				t.Fatal("Decode succeeded, want error")
			}
			if tc.want != nil && !errors.Is(err, tc.want) {
				t.Errorf("err = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestDecodeFutureVersionKeepsKnownFields(t *testing.T) {
	r, err := Decode([]byte(`{"v":2,"seq":9,"layer":"App","message":"hi","extra":true}`))
	if err != nil {
		t.Fatal(err)
	}
	if r.V != 2 || r.Seq != 9 || r.Message != "hi" {
		t.Errorf("Decode = %+v", r)
	}
}

func TestPlain(t *testing.T) {
	at := time.Date(2026, 1, 2, 3, 4, 5, 678_000_000, time.UTC)
	clock := at.Local().Format("15:04:05.000")
	for name, tc := range map[string]struct {
		rec  Record
		want string
	}{
		"no data": {
			rec:  Record{Time: at, Layer: "App", Level: "info", Message: "boot"},
			want: clock + " App [info] boot",
		},
		"data compacted": {
			rec:  Record{Time: at, Layer: "Network", Level: "debug", Message: "GET", Data: json.RawMessage("{\n  \"a\": [1, 2],\n  \"b\": {\"c\": 1.0}\n}")},
			want: clock + ` Network [debug] GET {"a":[1,2],"b":{"c":1.0}}`,
		},
		"control characters escaped, CRLF trimmed": {
			rec:  Record{Time: at, Layer: "App\x1b[2J", Level: "info", Message: "a\x1b[31mb\tc\r\nnext"},
			want: clock + ` App\x1b[2J [info] a\x1b[31mb c …`,
		},
		"multi-line message keeps the first line": {
			rec:  Record{Time: at, Layer: "Database", Level: "trace", Message: "SELECT *\nFROM users\nWHERE id = 1"},
			want: clock + " Database [trace] SELECT * …",
		},
		"error and non-main isolate are shown and sanitized": {
			rec: Record{
				Time:        at,
				Layer:       "Storage",
				IsolateName: "drift\x1b[2J",
				Level:       "error",
				Message:     "Migration failed",
				Error:       "SqliteException: bad\ncolumn\x9b2J",
			},
			want: clock + ` Storage@drift\x1b[2J [error] Migration failed ✗ SqliteException: bad \n column\x9b2J`,
		},
		"c1 control in data is escaped in plain": {
			rec: Record{
				Time:    at,
				Layer:   "App",
				Level:   "info",
				Message: "m",
				Data:    json.RawMessage("{\"k\":\"a\u009b2Jb\u007fc\"}"),
			},
			want: clock + ` App [info] m {"k":"a\x9b2Jb\x7fc"}`,
		},
	} {
		t.Run(name, func(t *testing.T) {
			if got := tc.rec.Plain(); got != tc.want {
				t.Errorf("Plain() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestJSONRoundTripPreservesOrderAndIsolate(t *testing.T) {
	b, err := os.ReadFile("../testdata/record_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	r, err := Decode(b)
	if err != nil {
		t.Fatal(err)
	}
	r.IsolateName = "worker"

	line := r.JSON()
	if bytes.Contains(line, []byte("\n")) {
		t.Fatalf("JSON() contains newline: %q", line)
	}
	got, err := Decode(line)
	if err != nil {
		t.Fatalf("Decode(JSON()): %v", err)
	}
	if got.IsolateName != "worker" || string(got.Data) != `{"status":200,"body":{"id":42,"name":"Jane","tags":["a","b"]},"duration_ms":12}` {
		t.Errorf("round-trip got IsolateName=%q Data=%s", got.IsolateName, got.Data)
	}
}

func TestFilterAndParseLevel(t *testing.T) {
	idx, ok := ParseLevel("CRITICAL")
	if !ok || Levels[idx].Severity != 600 {
		t.Fatalf("ParseLevel(CRITICAL) = (%d, %v), want severity 600", idx, ok)
	}
	if _, ok := ParseLevel("bogus"); ok {
		t.Fatal("ParseLevel(bogus) succeeded")
	}

	r := Record{
		Level:    "warning",
		Severity: 400,
		Layer:    "Network",
		Message:  "← 429 GET /items",
		Error:    "rate limited",
	}
	h := r.Haystack()
	f := Filter{
		MinSeverity: 400,
		Layers:      map[string]bool{"network": true},
		Query:       "rate limited",
	}
	if !f.Match(r, h) {
		t.Error("expected Filter.Match true")
	}
	f.Layers = map[string]bool{"auth": true}
	if f.Match(r, h) {
		t.Error("expected layer mismatch to reject")
	}
}

func FuzzDecodeAndPlain(f *testing.F) {
	f.Add([]byte(`{"v":1,"seq":1,"time":"2026-01-02T03:04:05Z","level":"info","layer":"App","message":"hi\u001b[2J","error":"boom\n\u009b2J","data":{"\u001b":"a\u007f"}}`))
	f.Add([]byte(`{"v":2,"seq":9,"message":"a\r\nb","data":[1,true,null]}`))
	f.Fuzz(func(t *testing.T, raw []byte) {
		r, err := Decode(raw)
		if err != nil {
			return
		}
		plain := r.Plain()
		if !utf8.ValidString(plain) {
			t.Fatalf("Plain() returned invalid UTF-8: %q", plain)
		}
		for _, c := range plain {
			if c == '\n' || c == '\r' || c == '\t' || termsafe.IsControl(c) {
				t.Fatalf("Plain() leaked control rune %U in %q", c, plain)
			}
		}
	})
}
