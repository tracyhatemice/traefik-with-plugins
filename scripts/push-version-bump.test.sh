#!/usr/bin/env bash
# Tests for push-version-bump.sh against throwaway local repositories.
#
# usage: scripts/push-version-bump.test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/push-version-bump.sh"

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

# new_setup <name>: a bare "origin" with one commit on main, plus a clone
# holding an unpushed bump commit (what the workflow has at push time).
new_setup() {
	local d=$tmp/$1
	git init -q --bare -b main "$d/origin.git"
	git clone -q "$d/origin.git" "$d/seed" 2>/dev/null
	echo "VERSION=v1" >"$d/seed/versions.conf"
	git -C "$d/seed" add versions.conf
	git -C "$d/seed" commit -q -m initial
	git -C "$d/seed" push -q origin HEAD:main
	git clone -q "$d/origin.git" "$d/run"
	echo "VERSION=v2" >"$d/run/versions.conf"
	git -C "$d/run" commit -q -am "Bump VERSION=v2"
}
remote_main() { git -C "$tmp/$1/origin.git" rev-parse main; }

# main unchanged: the bump lands.
new_setup clean
out=$(cd "$tmp/clean/run" && "$script" main 2>&1)
assert_eq "pushes the bump when main has not moved" 0 $?
assert_eq "main now points at the bump" "$(git -C "$tmp/clean/run" rev-parse HEAD)" "$(remote_main clean)"

# main moved (someone pushed while the run was building): step aside.
new_setup moved
git clone -q "$tmp/moved/origin.git" "$tmp/moved/human"
echo "docs" >"$tmp/moved/human/README"
git -C "$tmp/moved/human" add README
git -C "$tmp/moved/human" commit -q -m "human change"
git -C "$tmp/moved/human" push -q origin HEAD:main
human=$(remote_main moved)
out=$(cd "$tmp/moved/run" && "$script" main 2>&1)
assert_eq "exits 0 when main moved underneath" 0 $?
assert_eq "leaves the newer main alone" "$human" "$(remote_main moved)"
if [[ "$out" == *"::notice::"*"moved"* ]]; then
	pass "explains why the bump was not pushed"
else
	fail "explains why the bump was not pushed: got '$out'"
fi

# push rejected for another reason (main did not move): a real failure.
new_setup rejected
printf '#!/bin/sh\necho "denied by policy" >&2\nexit 1\n' >"$tmp/rejected/origin.git/hooks/pre-receive"
chmod +x "$tmp/rejected/origin.git/hooks/pre-receive"
before=$(remote_main rejected)
if (cd "$tmp/rejected/run" && "$script" main >/dev/null 2>&1); then
	fail "fails when the push is rejected and main did not move: exited 0"
else
	pass "fails when the push is rejected and main did not move"
fi
assert_eq "rejected push leaves main unchanged" "$before" "$(remote_main rejected)"

if ((failures > 0)); then
	echo "$failures test(s) failed"
	exit 1
fi
echo "all push-version-bump tests passed"
