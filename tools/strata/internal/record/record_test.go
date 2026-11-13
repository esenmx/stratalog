package record

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"testing"
	"time"
)

// The Dart contract test asserts VmStreamWriter produces this fixture; this
// one asserts strata decodes it.
func TestDecodeContractFixture(t *testing.T) {
	b, err := os.ReadFile("../../testdata/record_v1.json")
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
	} {
		t.Run(name, func(t *testing.T) {
			if got := tc.rec.Plain(); got != tc.want {
				t.Errorf("Plain() = %q, want %q", got, tc.want)
			}
		})
	}
}
