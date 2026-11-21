package vmservice

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestResolveTarget(t *testing.T) {
	for name, tc := range map[string]struct {
		arg      string // used as-is unless file is set
		filename string // optional filename override
		file     string // file content; arg becomes its path
		wantKind TargetKind
		want     string
	}{
		"stdin":                   {arg: "-", wantKind: TargetStdin, want: "-"},
		"ws uri":                  {arg: "ws://127.0.0.1:5000/abc=/ws", wantKind: TargetVMService, want: "ws://127.0.0.1:5000/abc=/ws"},
		"wss uri":                 {arg: "wss://host/abc=/ws", wantKind: TargetVMService, want: "wss://host/abc=/ws"},
		"http uri":                {arg: "http://127.0.0.1:5000/abc=/", wantKind: TargetVMService, want: "ws://127.0.0.1:5000/abc=/ws"},
		"http uri without slash":  {arg: "http://127.0.0.1:5000/abc=", wantKind: TargetVMService, want: "ws://127.0.0.1:5000/abc=/ws"},
		"https uri":               {arg: "https://host/abc=/", wantKind: TargetVMService, want: "wss://host/abc=/ws"},
		"file with ws uri":        {file: "ws://127.0.0.1:5000/abc=/ws\n", wantKind: TargetVMService, want: "ws://127.0.0.1:5000/abc=/ws"},
		"file with http uri":      {file: "http://127.0.0.1:5000/abc=/", wantKind: TargetVMService, want: "ws://127.0.0.1:5000/abc=/ws"},
		"write-service-info json": {file: `{"uri":"http://127.0.0.1:5000/abc=/"}`, wantKind: TargetVMService, want: "ws://127.0.0.1:5000/abc=/ws"},
		"flutter run stdout log": {
			file: "Launching lib/main.dart...\n" +
				"A Dart VM Service on iPhone 16 is available at: http://127.0.0.1:51111/old=/\n" +
				"Hot restart...\n" +
				"The Dart VM service is listening on http://127.0.0.1:52222/new=/\n" +
				"GET https://api.example.com/users/42\n",
			wantKind: TargetVMService,
			want:     "ws://127.0.0.1:52222/new=/ws",
		},
		"jsonl file by extension": {
			filename: "capture.jsonl",
			file:     `{"v":1,"seq":1,"time":"2026-01-02T03:04:05Z","level":"info","layer":"App","message":"hi"}` + "\n",
			wantKind: TargetJSONL,
		},
		"jsonl file auto-detected by record schema": {
			filename: "capture.log",
			file:     `{"v":1,"seq":1,"time":"2026-01-02T03:04:05Z","level":"info","layer":"App","message":"hi"}` + "\n",
			wantKind: TargetJSONL,
		},
	} {
		t.Run(name, func(t *testing.T) {
			arg := tc.arg
			want := tc.want
			if tc.file != "" {
				fname := tc.filename
				if fname == "" {
					fname = ".flutter.vmservice"
				}
				arg = filepath.Join(t.TempDir(), fname)
				if err := os.WriteFile(arg, []byte(tc.file), 0o600); err != nil {
					t.Fatal(err)
				}
				if tc.wantKind == TargetJSONL {
					want = arg
				}
			}
			got, err := Resolve(arg)
			if err != nil {
				t.Fatal(err)
			}
			if got.Kind != tc.wantKind || got.Value != want {
				t.Errorf("Resolve = %+v, want kind=%v value=%q", got, tc.wantKind, want)
			}
		})
	}
}

func TestResolveEnvFallbackWhenDefaultMissing(t *testing.T) {
	for name, tc := range map[string]struct{ strata, want string }{
		"VM_SERVICE_URI":                    {want: "ws://127.0.0.1:59999/tok=/ws"},
		"STRATA_TARGET over VM_SERVICE_URI": {strata: "ws://127.0.0.1:58888/s=/ws", want: "ws://127.0.0.1:58888/s=/ws"},
	} {
		t.Run(name, func(t *testing.T) {
			missing := filepath.Join(t.TempDir(), ".flutter.vmservice")
			t.Setenv("STRATA_TARGET", tc.strata)
			t.Setenv("VM_SERVICE_URI", "http://127.0.0.1:59999/tok=/")

			got, err := ResolveDefault(missing)
			if err != nil {
				t.Fatal(err)
			}
			if got.Kind != TargetVMService || got.Value != tc.want {
				t.Errorf("ResolveDefault = %+v, want %s", got, tc.want)
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
			_, err := Resolve(path)
			if err == nil {
				t.Fatal("Resolve succeeded, want error")
			}
			if got := errors.Is(err, ErrWaiting); got != tc.waiting {
				t.Errorf("errors.Is(err, ErrWaiting) = %v, want %v (err: %v)", got, tc.waiting, err)
			}
		})
	}
}
