package vmservice

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestResolveTarget(t *testing.T) {
	for name, tc := range map[string]struct {
		arg  string // used as-is unless file is set
		file string // file content; arg becomes its path
		want string
	}{
		"ws uri":                  {arg: "ws://127.0.0.1:5000/abc=/ws", want: "ws://127.0.0.1:5000/abc=/ws"},
		"wss uri":                 {arg: "wss://host/abc=/ws", want: "wss://host/abc=/ws"},
		"http uri":                {arg: "http://127.0.0.1:5000/abc=/", want: "ws://127.0.0.1:5000/abc=/ws"},
		"http uri without slash":  {arg: "http://127.0.0.1:5000/abc=", want: "ws://127.0.0.1:5000/abc=/ws"},
		"https uri":               {arg: "https://host/abc=/", want: "wss://host/abc=/ws"},
		"file with ws uri":        {file: "ws://127.0.0.1:5000/abc=/ws\n", want: "ws://127.0.0.1:5000/abc=/ws"},
		"file with http uri":      {file: "http://127.0.0.1:5000/abc=/", want: "ws://127.0.0.1:5000/abc=/ws"},
		"write-service-info json": {file: `{"uri":"http://127.0.0.1:5000/abc=/"}`, want: "ws://127.0.0.1:5000/abc=/ws"},
	} {
		t.Run(name, func(t *testing.T) {
			arg := tc.arg
			if tc.file != "" {
				arg = filepath.Join(t.TempDir(), ".flutter.vmservice")
				if err := os.WriteFile(arg, []byte(tc.file), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			got, err := ResolveTarget(arg)
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Errorf("ResolveTarget = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestResolveTargetErrors(t *testing.T) {
	for name, tc := range map[string]struct {
		file    *string // nil: no file at all
		waiting bool
	}{
		"missing file":   {waiting: true},
		"empty file":     {file: new(""), waiting: true},
		"json sans uri":  {file: new(`{"port":1}`)},
		"not a uri":      {file: new("hello")},
		"malformed json": {file: new(`{"uri":`)},
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), ".flutter.vmservice")
			if tc.file != nil {
				if err := os.WriteFile(path, []byte(*tc.file), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			_, err := ResolveTarget(path)
			if err == nil {
				t.Fatal("ResolveTarget succeeded, want error")
			}
			if got := errors.Is(err, ErrWaiting); got != tc.waiting {
				t.Errorf("errors.Is(err, ErrWaiting) = %v, want %v (err: %v)", got, tc.waiting, err)
			}
		})
	}
}
