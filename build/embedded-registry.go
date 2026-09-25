// Embedded plugin registry, copied into Traefik's pkg/plugins at build time.
// Adapted from github.com/david-garcia-garcia/traefik-with-plugins (MIT; see
// build/NOTICE).
package plugins

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strings"

	"github.com/mitchellh/mapstructure"
	"github.com/rs/zerolog/log"

	robotstxt "github.com/solution-libre/traefik-plugin-robots-txt"
	captcha "github.com/tracyhatemice/captcha-protect"
	modsecurity "github.com/tracyhatemice/traefik-modsecurity-plugin"
)

// embeddedPlugin wraps a plugin compiled into the binary.
// createConfig and callNew mirror the CreateConfig/New pair Yaegi calls.
type embeddedPlugin struct {
	createConfig func() any
	callNew      func(ctx context.Context, next http.Handler, config any, name string) (http.Handler, error)
}

// basePluginRegistry maps the default plugin key (the name used under
// "plugin.<key>" in dynamic configuration) to the embedded plugin.
var basePluginRegistry = map[string]embeddedPlugin{
	"modsecurity": {
		createConfig: func() any { return modsecurity.CreateConfig() },
		callNew: func(ctx context.Context, next http.Handler, config any, name string) (http.Handler, error) {
			return modsecurity.New(ctx, next, config.(*modsecurity.Config), name)
		},
	},
	"robots-txt": {
		createConfig: func() any { return robotstxt.CreateConfig() },
		callNew: func(ctx context.Context, next http.Handler, config any, name string) (http.Handler, error) {
			return robotstxt.New(ctx, next, config.(*robotstxt.Config), name)
		},
	},
	"captcha-protect": {
		createConfig: func() any { return captcha.CreateConfig() },
		callNew: func(ctx context.Context, next http.Handler, config any, name string) (http.Handler, error) {
			return captcha.New(ctx, next, config.(*captcha.Config), name)
		},
	},
}

// EmbeddedPluginRegistry is basePluginRegistry with keys remapped from the
// environment: TRAEFIK_EMBEDDED_<KEY>_KEY=<custom> registers the plugin under
// <custom> instead of its default key. <KEY> is the default key uppercased
// with "-" replaced by "_", e.g. TRAEFIK_EMBEDDED_CAPTCHA_PROTECT_KEY.
var EmbeddedPluginRegistry = buildPluginRegistry(os.Getenv)

func remapEnvVar(defaultKey string) string {
	return "TRAEFIK_EMBEDDED_" + strings.ToUpper(strings.ReplaceAll(defaultKey, "-", "_")) + "_KEY"
}

func buildPluginRegistry(getenv func(string) string) map[string]embeddedPlugin {
	registry := make(map[string]embeddedPlugin, len(basePluginRegistry))
	for defaultKey, plugin := range basePluginRegistry {
		key := defaultKey
		if custom := strings.TrimSpace(getenv(remapEnvVar(defaultKey))); custom != "" {
			key = custom
		}
		registry[key] = plugin
	}
	return registry
}

func registryKeys(registry map[string]embeddedPlugin) []string {
	keys := make([]string, 0, len(registry))
	for k := range registry {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// IsEmbeddedPlugin reports whether pluginName is compiled into the binary.
func IsEmbeddedPlugin(pluginName string) bool {
	_, ok := EmbeddedPluginRegistry[pluginName]
	return ok
}

// BuildEmbeddedPlugin decodes config the same way Traefik's Yaegi builder does
// and returns a constructor that calls the plugin's New directly.
func BuildEmbeddedPlugin(_ context.Context, pluginName string, config map[string]any, middlewareName string) (Constructor, error) {
	plugin, ok := EmbeddedPluginRegistry[pluginName]
	if !ok {
		return nil, fmt.Errorf("unknown embedded plugin: %s (available: %s)", pluginName, strings.Join(registryKeys(EmbeddedPluginRegistry), ", "))
	}

	log.Debug().Str("plugin", pluginName).Str("middleware", middlewareName).Msg("Building embedded plugin")

	cfg := plugin.createConfig()

	if len(config) > 0 {
		decoder, err := mapstructure.NewDecoder(&mapstructure.DecoderConfig{
			DecodeHook:       mapstructure.StringToSliceHookFunc(","),
			WeaklyTypedInput: true,
			Result:           cfg,
		})
		if err != nil {
			return nil, fmt.Errorf("failed to create configuration decoder: %w", err)
		}

		if err := decoder.Decode(config); err != nil {
			return nil, fmt.Errorf("failed to decode configuration: %w", err)
		}
	}

	return func(ctx context.Context, next http.Handler) (http.Handler, error) {
		return plugin.callNew(ctx, next, cfg, middlewareName)
	}, nil
}
