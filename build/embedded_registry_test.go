package plugins

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

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
