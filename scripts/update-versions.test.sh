#!/usr/bin/env bash
# Tests for update-versions.sh. Remote lookups are replaced by fixtures, so
# this runs offline.
#
# usage: scripts/update-versions.test.sh
set -uo pipefail

# shellcheck source=scripts/update-versions.sh
source "$(dirname "$0")/update-versions.sh"

failures=0
pass() { echo "ok   - $1"; }
fail() {
	echo "FAIL - $1"
	failures=$((failures + 1))
}
assert_eq() { # assert_eq <description> <expected> <actual>
	if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi
}

# --- pick_tag -----------------------------------------------------------------

traefik_tags=$'v2.11.57\nv3.6.25\nv3.7.12\nv3.7.13\nv3.8.0-rc.1\nv4.0.0'

assert_eq "stable-major stays within the pinned major and skips prereleases" v3.7.13 \
	"$(pick_tag stable-major v3.7.12 <<<"$traefik_tags")"
assert_eq "stable crosses majors" v4.0.0 \
	"$(pick_tag stable v3.7.12 <<<"$traefik_tags")"
assert_eq "never downgrades" v3.7.13 \
	"$(pick_tag stable-major v3.7.13 <<<$'v3.7.12\nv3.6.0')"
assert_eq "no candidates keeps current" v1.0.0 \
	"$(pick_tag stable-major v1.0.0 <<<"")"
assert_eq "compares numerically, not lexically" v0.2.10 \
	"$(pick_tag stable-major v0.2.9 <<<$'v0.2.10\nv0.2.8')"
assert_eq "minor 10 beats minor 9" v3.10.0 \
	"$(pick_tag stable-major v3.9.9 <<<$'v3.10.0\nv3.9.10')"
assert_eq "prerelease pin waits for a newer stable" v2.0.0-beta.1 \
	"$(pick_tag stable-major v2.0.0-beta.1 <<<$'v1.2.1\nv2.0.0-beta.2')"
assert_eq "prerelease pin moves to its stable release" v2.0.0 \
	"$(pick_tag stable-major v2.0.0-beta.1 <<<$'v1.2.1\nv2.0.0-beta.2\nv2.0.0')"
assert_eq "tags without a v prefix work" 1.3.0 \
	"$(pick_tag stable-major 1.2.3 <<<$'1.3.0\n1.2.4')"
assert_eq "non-semver tags are ignored" v1.2.0 \
	"$(pick_tag stable v1.1.0 <<<$'latest\nv1\nv1.3\nv1.2.0\nnightly-2026')"
assert_eq "build metadata is not a prerelease" v1.2.0+meta \
	"$(pick_tag stable-major v1.1.0 <<<$'v1.2.0+meta')"

sha=9cd7e2d5866c2bd764d192298a2961c6299d1297
warning=$(pick_tag stable-major "$sha" <<<$'v1.0.0\nv2.1.0' 2>&1 >/dev/null)
assert_eq "stable-major on a SHA falls back to stable" v2.1.0 \
	"$(pick_tag stable-major "$sha" <<<$'v1.0.0\nv2.1.0' 2>/dev/null)"
if [[ "$warning" == *"not a semver tag"* ]]; then
	pass "stable-major on a SHA warns"
else
	fail "stable-major on a SHA warns: got '$warning'"
fi

# --- update flow with fake remotes ---------------------------------------------

remote_tags() {
	case $1 in
	github.com/example/traefik) printf '%s\n' v3.7.12 v3.7.13 v4.0.0 ;;
	github.com/example/tagged) printf '%s\n' v1.0.0 v1.1.0 ;;
	github.com/example/offline) return 1 ;;
	*) return 0 ;;
	esac
}
remote_head() {
	case $1 in
	github.com/example/fork) echo 1111111111111111111111111111111111111111 ;;
	github.com/example/garbage) echo "not-a-sha" ;;
	esac
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/versions.conf" <<'EOF'
# comment kept
TRAEFIK_REPO=github.com/example/traefik
TRAEFIK_VERSION=v3.7.12
TRAEFIK_TRACK=stable-major

PLUGIN_TAGGED_REPO=github.com/example/tagged
PLUGIN_TAGGED_VERSION=v1.0.0
PLUGIN_TAGGED_TRACK=pinned

PLUGIN_FORK_REPO=github.com/example/fork
PLUGIN_FORK_VERSION=0000000000000000000000000000000000000000
PLUGIN_FORK_TRACK=head
EOF

gh_out="$tmp/github_output"
: >"$gh_out"
out=$(GITHUB_OUTPUT=$gh_out main "$tmp/versions.conf")
assert_eq "main exits 0 on success" 0 $?
assert_eq "writes changed=true to GITHUB_OUTPUT" "changed=true" "$(grep '^changed=' "$gh_out")"
assert_eq "writes the change lines to GITHUB_OUTPUT" \
	$'changes<<CHANGES_EOF\nTRAEFIK_VERSION v3.7.12 -> v3.7.13\nPLUGIN_FORK_VERSION 0000000000000000000000000000000000000000 -> 1111111111111111111111111111111111111111\nCHANGES_EOF' \
	"$(sed -n '/^changes<</,/^CHANGES_EOF$/p' "$gh_out")"
assert_eq "main reports each change" \
	$'TRAEFIK_VERSION v3.7.12 -> v3.7.13\nPLUGIN_FORK_VERSION 0000000000000000000000000000000000000000 -> 1111111111111111111111111111111111111111' \
	"$out"
assert_eq "traefik bumped in file" v3.7.13 "$(conf_get "$tmp/versions.conf" TRAEFIK_VERSION)"
assert_eq "pinned plugin untouched" v1.0.0 "$(conf_get "$tmp/versions.conf" PLUGIN_TAGGED_VERSION)"
assert_eq "head plugin moved to remote HEAD" 1111111111111111111111111111111111111111 \
	"$(conf_get "$tmp/versions.conf" PLUGIN_FORK_VERSION)"
assert_eq "comments preserved" "# comment kept" "$(head -n 1 "$tmp/versions.conf")"

assert_eq "second run finds nothing to change" "" "$(main "$tmp/versions.conf")"

: >"$gh_out"
GITHUB_OUTPUT=$gh_out main "$tmp/versions.conf" >/dev/null
assert_eq "writes changed=false to GITHUB_OUTPUT" "changed=false" "$(grep '^changed=' "$gh_out")"

printf 'TRAEFIK_REPO=github.com/example/traefik\r\nTRAEFIK_VERSION=v3.7.12\r\nTRAEFIK_TRACK=stable-major\r\n' >"$tmp/crlf.conf"
assert_eq "CRLF line endings are tolerated" "TRAEFIK_VERSION v3.7.12 -> v3.7.13" "$(main "$tmp/crlf.conf" 2>&1)"
assert_eq "CRLF file gets a clean value" v3.7.13 "$(conf_get "$tmp/crlf.conf" TRAEFIK_VERSION)"

# Failures must leave the file exactly as it was.
expect_failure() { # expect_failure <description> <conf body>
	printf '%s\n' "$2" >"$tmp/bad.conf"
	cp "$tmp/bad.conf" "$tmp/bad.orig"
	if main "$tmp/bad.conf" >/dev/null 2>&1; then
		fail "$1: expected non-zero exit"
	elif ! cmp -s "$tmp/bad.conf" "$tmp/bad.orig"; then
		fail "$1: file was modified"
	else
		pass "$1"
	fi
}

ok_then=$'PLUGIN_TAGGED_REPO=github.com/example/tagged\nPLUGIN_TAGGED_VERSION=v1.0.0\nPLUGIN_TAGGED_TRACK=stable-major'
expect_failure "unreachable remote fails without writing" \
	"$ok_then"$'\nPLUGIN_OFF_REPO=github.com/example/offline\nPLUGIN_OFF_VERSION=v1.0.0\nPLUGIN_OFF_TRACK=stable'
expect_failure "unknown track fails without writing" \
	"$ok_then"$'\nPLUGIN_X_REPO=github.com/example/tagged\nPLUGIN_X_VERSION=v1.0.0\nPLUGIN_X_TRACK=newest'
expect_failure "missing track fails without writing" \
	"$ok_then"$'\nPLUGIN_X_REPO=github.com/example/tagged\nPLUGIN_X_VERSION=v1.0.0'
expect_failure "unresolvable HEAD fails without writing" \
	"$ok_then"$'\nPLUGIN_G_REPO=github.com/example/garbage\nPLUGIN_G_VERSION=v1.0.0\nPLUGIN_G_TRACK=head'
expect_failure "no components fails" "# empty"

if ((failures > 0)); then
	echo "$failures test(s) failed"
	exit 1
fi
echo "all updater tests passed"
