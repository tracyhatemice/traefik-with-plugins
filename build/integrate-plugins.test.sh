#!/usr/bin/env bash
# Tests for integrate-plugins.sh, offline: plugin "remotes" are local bare
# repositories (git rewrites https:// to them) and `go` is a stub that records
# its arguments.
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
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$tmp/remote/.insteadOf" GIT_CONFIG_VALUE_0="https://"

# fake_plugin <module path>: a bare repo at the module's https URL, tagged v1.0.0.
fake_plugin() {
	local src=$tmp/src/$1
	git init -q -b main "$src"
	printf 'module %s\n\ngo 1.21\n' "$1" >"$src/go.mod"
	git -C "$src" add go.mod
	git -C "$src" commit -q -m init
	git -C "$src" tag v1.0.0
	git clone -q --bare "$src" "$tmp/remote/$1.git"
}
fake_plugin github.com/example/plugin

mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho "$*" >>"%s"\n' "$tmp/go.log" >"$tmp/bin/go"
chmod +x "$tmp/bin/go"
export PATH="$tmp/bin:$PATH"

# run <conf body> <registry body>: run the script in a fresh workdir; prints its
# stderr, returns its status.
run() {
	local w
	w=$(mktemp -d "$tmp/work.XXXX")
	printf '%s' "$1" >"$w/versions.conf"
	printf '%s\n' "$2" >"$w/registry.go"
	: >"$tmp/go.log"
	(cd "$w" && { sh "$script" versions.conf "$w/plugins" registry.go >/dev/null; } 2>&1)
}

conf_crlf=$'PLUGIN_PLUGIN_REPO=github.com/example/plugin\r\nPLUGIN_PLUGIN_VERSION=v1.0.0\r\n'

run "$conf_crlf" 'import p "github.com/example/plugin"' >/dev/null
assert_eq "wires a registered plugin (CRLF conf)" 0 $?
assert_eq "requires and replaces the module with the checkout" \
	"mod edit -require=github.com/example/plugin@v0.0.0-00010101000000-000000000000 -replace=github.com/example/plugin=$(ls -d "$tmp"/work.*)/plugins/plugin" \
	"$(cat "$tmp/go.log")"
rm -rf "$tmp"/work.*

err=$(run "$conf_crlf" 'import other "github.com/example/other"')
assert_eq "fails when the plugin is not in the registry" 1 $?
if [[ "$err" == *"github.com/example/plugin (PLUGIN_PLUGIN) is not imported"* ]]; then
	pass "names the unregistered plugin"
else
	fail "names the unregistered plugin: got '$err'"
fi

run "$conf_crlf" 'import p "githubXcom/example/plugin"' >/dev/null
assert_eq "a lookalike import path does not count as registered" 1 $?

if ((failures > 0)); then
	echo "$failures test(s) failed"
	exit 1
fi
echo "all integrate-plugins tests passed"
