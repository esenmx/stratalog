// Package vmservice speaks just enough Dart VM service JSON-RPC to stream
// stratalog records: streamListen, getVM, getIsolate and the
// ext.stratalog.history extension.
package vmservice

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"strings"
)

// ErrWaiting reports a target file that does not exist yet, or is still
// empty — the app is not running.
var ErrWaiting = errors.New("waiting")

// ResolveTarget turns a target into the VM service WebSocket URL. arg is a
// ws(s):// or http(s):// URI, or a file holding either a URI (the
// `.flutter.vmservice` the run launcher writes) or `{"uri": "..."}`
// (`dart run --write-service-info`).
func ResolveTarget(arg string) (string, error) {
	if hasScheme(arg) {
		return wsURL(arg)
	}
	b, err := os.ReadFile(arg)
	if errors.Is(err, fs.ErrNotExist) {
		return "", fmt.Errorf("%w for %s", ErrWaiting, arg)
	}
	if err != nil {
		return "", err
	}
	content := strings.TrimSpace(string(b))
	if content == "" {
		return "", fmt.Errorf("%w for %s", ErrWaiting, arg)
	}
	if strings.HasPrefix(content, "{") {
		var info struct {
			URI string `json:"uri"`
		}
		if err := json.Unmarshal([]byte(content), &info); err != nil {
			return "", fmt.Errorf("%s: %w", arg, err)
		}
		if info.URI == "" {
			return "", fmt.Errorf("%s: no \"uri\" field", arg)
		}
		content = info.URI
	}
	if !hasScheme(content) {
		return "", fmt.Errorf("%s: not a VM service URI: %q", arg, content)
	}
	return wsURL(content)
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
