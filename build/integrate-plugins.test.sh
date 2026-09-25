#!/usr/bin/env bash
# Tests for integrate-plugins.sh, offline: `go` is a stub that records its
# arguments and serves module directories from a fake module cache.
#
# usage: build/integrate-plugins.test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/integrate-plugins.sh"

failures=0
pass() { echo "ok   - $1"; }
fail() {
	echo "FAIL - $1"
	failures=$((failures + 1))
}
assert_eq() { # assert_eq <description> <expected> <actual>
	if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Fake module cache: `go list -m -f {{.Dir}} <module>` prints $tmp/modcache/<module>.
mkdir -p "$tmp/modcache/github.com/example/plugin" "$tmp/modcache/github.com/example/nolicense"
echo "plugin license" >"$tmp/modcache/github.com/example/plugin/LICENSE"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/go" <<EOF
#!/bin/sh
echo "\$*" >>"$tmp/go.log"
if [ "\$1 \$2" = "list -m" ]; then echo "$tmp/modcache/\$5"; fi
EOF
chmod +x "$tmp/bin/go"
export PATH="$tmp/bin:$PATH"

# run <conf body> <registry body>: run the script in a fresh workdir ($w);
# prints its stderr, returns its status.
run() {
	w=$(mktemp -d "$tmp/work.XXXX")
	printf '%s' "$1" >"$w/versions.conf"
	printf '%s\n' "$2" >"$w/registry.go"
	: >"$tmp/go.log"
	(cd "$w" && { sh "$script" versions.conf registry.go "$w/licenses" >/dev/null; } 2>&1)
}

conf=$'PLUGIN_PLUGIN_REPO=github.com/example/plugin\r\nPLUGIN_PLUGIN_VERSION=v1.0.0\r\n'
registered='import p "github.com/example/plugin"'

run "$conf" "$registered" >/dev/null
assert_eq "wires a registered plugin (CRLF conf)" 0 $?
assert_eq "fetches the module at its version with go get" \
	"get github.com/example/plugin@v1.0.0" "$(grep '^get ' "$tmp/go.log")"
assert_eq "copies the plugin's license from the module cache" \
	"plugin license" "$(cat "$w/licenses/plugin/LICENSE" 2>/dev/null)"

sha=cbca3a9376ae1c55ab274ed1625c056192007879
run "PLUGIN_PLUGIN_REPO=github.com/example/plugin"$'\n'"PLUGIN_PLUGIN_VERSION=$sha" "$registered" >/dev/null
assert_eq "a commit SHA works as the version" "get github.com/example/plugin@$sha" "$(grep '^get ' "$tmp/go.log")"

err=$(run "$conf" 'import other "github.com/example/other"')
assert_eq "fails when the plugin is not in the registry" 1 $?
if [[ "$err" == *"github.com/example/plugin (PLUGIN_PLUGIN) is not imported"* ]]; then
	pass "names the unregistered plugin"
else
	fail "names the unregistered plugin: got '$err'"
fi
assert_eq "does not fetch an unregistered plugin" "" "$(cat "$tmp/go.log")"

run "$conf" 'import p "githubXcom/example/plugin"' >/dev/null
assert_eq "a lookalike import path does not count as registered" 1 $?

err=$(run $'PLUGIN_NOLICENSE_REPO=github.com/example/nolicense\nPLUGIN_NOLICENSE_VERSION=v1.0.0' \
	'import n "github.com/example/nolicense"')
assert_eq "fails when a plugin ships no license file" 1 $?
if [[ "$err" == *"no license file in github.com/example/nolicense@v1.0.0"* ]]; then
	pass "names the plugin without a license"
else
	fail "names the plugin without a license: got '$err'"
fi

if ((failures > 0)); then
	echo "$failures test(s) failed"
	exit 1
fi
echo "all integrate-plugins tests passed"
