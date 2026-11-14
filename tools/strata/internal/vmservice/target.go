// Package vmservice speaks Dart VM service JSON-RPC to stream or snapshot
// stratalog records (streamListen, getVM, getIsolate, ext.stratalog.history)
// and resolves VM service URIs, runner logs, and NDJSON replay targets.
package vmservice

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/esenmx/stratalog/tools/strata/internal/record"
)

// ErrWaiting reports a target file that does not exist yet, or is still
// empty — the app is not running or has not written its service URI yet.
var ErrWaiting = errors.New("waiting")

// TargetKind classifies what [Resolve] found.
type TargetKind int

// Supported target sources.
const (
	TargetVMService TargetKind = iota // ws(s)://… VM service WebSocket URL
	TargetJSONL                       // path to an NDJSON record capture file
	TargetStdin                       // "-" standard input
)

// Target is a resolved record source.
type Target struct {
	Kind  TargetKind
	Value string // ws(s):// URL, file path, or "-"
}

// vmServiceLogLine matches `flutter run` and `dart run --observe` banner lines
// announcing a VM service HTTP or WebSocket URI.
var vmServiceLogURI = regexp.MustCompile(`(?i)vm service[^\n]*?((?:https?|wss?)://[^\s]+)`)

// ResolveDefault resolves the default target file, falling back to
// STRATA_TARGET or VM_SERVICE_URI when the default file is waiting.
func ResolveDefault(defaultFile string) (Target, error) {
	t, err := Resolve(defaultFile)
	if errors.Is(err, ErrWaiting) {
		for _, env := range []string{"STRATA_TARGET", "VM_SERVICE_URI"} {
			if v := strings.TrimSpace(os.Getenv(env)); v != "" {
				return Resolve(v)
			}
		}
	}
	return t, err
}

// Resolve turns arg into a [Target]:
//   - "-" reads NDJSON records from stdin;
//   - a ws(s):// or http(s):// URI connects to that VM service;
//   - a .jsonl/.ndjson path (or a file whose first line is a record_v1 object)
//     replays NDJSON records;
//   - a file holding a VM service URI, `{"uri": "..."}` (--write-service-info),
//     or `flutter run` / `dart run` stdout log lines extracts the latest URI.
func Resolve(arg string) (Target, error) {
	if arg == "-" {
		return Target{Kind: TargetStdin, Value: "-"}, nil
	}
	if hasScheme(arg) {
		u, err := wsURL(arg)
		if err != nil {
			return Target{}, err
		}
		return Target{Kind: TargetVMService, Value: u}, nil
	}

	ext := strings.ToLower(filepath.Ext(arg))
	isJSONLExt := ext == ".jsonl" || ext == ".ndjson"

	b, err := os.ReadFile(arg)
	if errors.Is(err, fs.ErrNotExist) {
		return Target{}, fmt.Errorf("%w for %s", ErrWaiting, arg)
	}
	if err != nil {
		return Target{}, err
	}
	if isJSONLExt {
		return Target{Kind: TargetJSONL, Value: arg}, nil
	}

	content := strings.TrimSpace(string(b))
	if content == "" {
		return Target{}, fmt.Errorf("%w for %s", ErrWaiting, arg)
	}
	if strings.HasPrefix(content, "{") {
		firstLine, _, _ := strings.Cut(content, "\n")
		if _, recErr := record.Decode([]byte(firstLine)); recErr == nil {
			return Target{Kind: TargetJSONL, Value: arg}, nil
		}
		var info struct {
			URI string `json:"uri"`
		}
		if err := json.Unmarshal([]byte(content), &info); err != nil {
			return Target{}, fmt.Errorf("%s: %w", arg, err)
		}
		if info.URI == "" {
			return Target{}, fmt.Errorf("%s: no \"uri\" field", arg)
		}
		u, err := wsURL(info.URI)
		if err != nil {
			return Target{}, err
		}
		return Target{Kind: TargetVMService, Value: u}, nil
	}
	if hasScheme(content) && !strings.ContainsAny(content, " \t\r\n") {
		u, err := wsURL(content)
		if err != nil {
			return Target{}, err
		}
		return Target{Kind: TargetVMService, Value: u}, nil
	}
	if matches := vmServiceLogURI.FindAllStringSubmatch(content, -1); len(matches) > 0 {
		last := matches[len(matches)-1][1]
		u, err := wsURL(last)
		if err != nil {
			return Target{}, err
		}
		return Target{Kind: TargetVMService, Value: u}, nil
	}
	return Target{}, fmt.Errorf("%s: not a VM service URI: %q", arg, content)
}

func hasScheme(s string) bool {
	for _, p := range []string{"ws://", "wss://", "http://", "https://"} {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

// wsURL rewrites an http(s) VM service URI to its ws(s)://…/ws endpoint;
// ws(s) URIs pass through.
func wsURL(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "ws", "wss":
		return u.String(), nil
	case "http":
		u.Scheme = "ws"
	case "https":
		u.Scheme = "wss"
	default:
		return "", fmt.Errorf("unsupported scheme %q", u.Scheme)
	}
	if !strings.HasSuffix(u.Path, "/ws") {
		u.Path = strings.TrimSuffix(u.Path, "/") + "/ws"
	}
	return u.String(), nil
}
