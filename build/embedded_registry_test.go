package plugins

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

func TestEmbeddedRegistryDefaultKeys(t *testing.T) {
	registry := buildPluginRegistry(func(string) string { return "" })

	want := []string{"captcha-protect", "modsecurity", "robots-txt"}
	if got := registryKeys(registry); !reflect.DeepEqual(got, want) {
		t.Fatalf("keys = %v, want %v", got, want)
	}
}

func TestEmbeddedRegistryRemapsKeyFromEnv(t *testing.T) {
	env := map[string]string{"TRAEFIK_EMBEDDED_CAPTCHA_PROTECT_KEY": " captcha "}
	registry := buildPluginRegistry(func(k string) string { return env[k] })

	want := []string{"captcha", "modsecurity", "robots-txt"}
	if got := registryKeys(registry); !reflect.DeepEqual(got, want) {
		t.Fatalf("keys = %v, want %v", got, want)
	}
}

func TestBuildEmbeddedPluginDecodesStringValuedConfig(t *testing.T) {
	// Labels and env deliver every value as a string; "true" must decode into
	// robots-txt's bool Overwrite field exactly as it does under Yaegi.
	config := map[string]any{
		"customRules": "User-agent: *\nDisallow: /private/\n",
		"overwrite":   "true",
	}

	constructor, err := BuildEmbeddedPlugin(context.Background(), "robots-txt", config, "robots@file")
	if err != nil {
		t.Fatalf("BuildEmbeddedPlugin: %v", err)
	}

	backend := http.HandlerFunc(func(rw http.ResponseWriter, _ *http.Request) {
		rw.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(rw, "User-agent: *\nDisallow: /backend-only/\n")
	})
	handler, err := constructor(context.Background(), backend)
	if err != nil {
		t.Fatalf("constructor: %v", err)
	}

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/robots.txt", nil))

	body := rec.Body.String()
	if !strings.Contains(body, "Disallow: /private/") {
		t.Errorf("body missing custom rule:\n%s", body)
	}
	if strings.Contains(body, "/backend-only/") {
		t.Errorf("overwrite=true should drop backend rules, got:\n%s", body)
	}
}

func TestBuildEmbeddedPluginUnknownKey(t *testing.T) {
	_, err := BuildEmbeddedPlugin(context.Background(), "nope", nil, "x@file")
	if err == nil || !strings.Contains(err.Error(), "unknown embedded plugin: nope") {
		t.Fatalf("err = %v, want unknown embedded plugin error", err)
	}
}

// embeddedUnwrapWriter mirrors Traefik v3.8's respondingtimeout/tap wrappers:
// it exposes the underlying writer only through Unwrap, not http.Flusher or http.Hijacker.
type embeddedUnwrapWriter struct {
	http.ResponseWriter
}

func (w *embeddedUnwrapWriter) Unwrap() http.ResponseWriter {
	return w.ResponseWriter
}

type embeddedRootWriter struct {
	http.ResponseWriter
	writeDeadline time.Time
	fullDuplex    bool
	hijacked      bool
}

func (w *embeddedRootWriter) SetWriteDeadline(d time.Time) error {
	w.writeDeadline = d
	return nil
}

func (w *embeddedRootWriter) EnableFullDuplex() error {
	w.fullDuplex = true
	return nil
}

func (w *embeddedRootWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	w.hijacked = true
	return nil, nil, nil
}

func TestBuildEmbeddedPluginWrapsExternalResponseWriter(t *testing.T) {
	// robots-txt wraps rw in a buffering ResponseWriter without Unwrap and
	// type-asserts http.Hijacker directly. BuildEmbeddedPlugin must wrap it with
	// wrapExternal like Yaegi/Wasm so ResponseController deadlines, full duplex,
	// and hijacking work across both unwrap-only upstream writers (respondingTimeouts,
	// tap) and non-unwrapping plugin writers.
	config := map[string]any{
		"customRules": "User-agent: *\nDisallow: /private/\n",
	}
	constructor, err := BuildEmbeddedPlugin(context.Background(), "robots-txt", config, "robots@file")
	if err != nil {
		t.Fatalf("BuildEmbeddedPlugin: %v", err)
	}

	deadline := time.Unix(1_700_000_000, 0)
	backend := http.HandlerFunc(func(rw http.ResponseWriter, _ *http.Request) {
		rc := http.NewResponseController(rw)
		if err := rc.SetWriteDeadline(deadline); err != nil {
			t.Errorf("SetWriteDeadline: %v", err)
		}
		if err := rc.EnableFullDuplex(); err != nil {
			t.Errorf("EnableFullDuplex: %v", err)
		}
		if _, _, err := rc.Hijack(); err != nil {
			t.Errorf("Hijack: %v", err)
		}
	})

	handler, err := constructor(context.Background(), backend)
	if err != nil {
		t.Fatalf("constructor: %v", err)
	}

	root := &embeddedRootWriter{ResponseWriter: httptest.NewRecorder()}
	handler.ServeHTTP(&embeddedUnwrapWriter{ResponseWriter: root}, httptest.NewRequest(http.MethodGet, "/robots.txt", nil))

	if !root.writeDeadline.Equal(deadline) {
		t.Errorf("writeDeadline = %v, want %v", root.writeDeadline, deadline)
	}
	if !root.fullDuplex {
		t.Error("EnableFullDuplex did not reach root ResponseWriter")
	}
	if !root.hijacked {
		t.Error("Hijack did not reach root ResponseWriter")
	}
}

func TestEmbeddedPluginsSlogWritesToTraefikLogger(t *testing.T) {
	// Traefik's logger setup replaces log.Logger after init; slog must follow it.
	var buf bytes.Buffer
	prev := log.Logger
	log.Logger = zerolog.New(&buf)
	t.Cleanup(func() { log.Logger = prev })

	slog.Default().With("middlewareName", "waf@file").Error("Failed to send request", "error", errors.New("connection refused"), "attempts", 2)

	var entry map[string]any
	if err := json.Unmarshal(buf.Bytes(), &entry); err != nil {
		t.Fatalf("slog did not reach Traefik's logger: %q: %v", buf.String(), err)
	}
	// Errors render as strings, like Traefik's own error fields.
	want := map[string]any{"level": "error", "message": "Failed to send request", "middlewareName": "waf@file", "error": "connection refused", "attempts": float64(2)}
	for k, v := range want {
		if entry[k] != v {
			t.Errorf("%s = %v, want %v (entry %v)", k, entry[k], v, entry)
		}
	}
	// Traefik's logger stamps the time itself; a second "time" key would duplicate it in JSON output.
	if _, ok := entry["time"]; ok {
		t.Errorf("slog handler added its own time field: %v", entry)
	}
}

func TestEmbeddedPluginsSlogFollowsTraefikLogLevel(t *testing.T) {
	// Traefik sets log.Logger's level after init. Records below it must be
	// dropped at the slog layer, before their attributes are converted.
	prev := log.Logger
	log.Logger = zerolog.New(io.Discard).Level(zerolog.InfoLevel)
	t.Cleanup(func() { log.Logger = prev })

	if slog.Default().Enabled(context.Background(), slog.LevelDebug) {
		t.Error("debug is enabled while Traefik's logger is at info")
	}
	if !slog.Default().Enabled(context.Background(), slog.LevelInfo) {
		t.Error("info is disabled while Traefik's logger is at info")
	}
}
