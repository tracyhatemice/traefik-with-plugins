# Traefik with Embedded Plugins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A GitHub Actions pipeline that builds Traefik with modsecurity, robots-txt and captcha-protect compiled into the binary for linux/amd64 and linux/arm64, publishes it as `ghcr.io/tracyhatemice/traefik`, and rebuilds automatically when Traefik or a plugin releases.

**Architecture:** `versions.conf` pins every component with a track policy. `scripts/update-versions.sh` moves pins forward. A multi-stage Dockerfile fetches Traefik, builds its dashboard once, wires each plugin in as a Go `replace` of a pinned checkout, patches Traefik's plugin builder to consult an in-binary registry before Yaegi, and cross-compiles per target. One workflow tests the scripts, checks upstream daily, builds and smoke-tests both architectures, publishes from `main` only, and commits version bumps only after the image is pushed.

**Tech Stack:** Go (Traefik v3.7, `golang:1.26-alpine`, `GOTOOLCHAIN=auto`), Node 24 + Yarn 4 (Traefik webui), Docker Buildx / BuildKit, bash + POSIX sh, jq, curl, GitHub Actions, GHCR.

**Spec:** `docs/superpowers/specs/2026-09-24-traefik-with-plugins-design.md`

**Provenance:** Every file below was prototyped and verified before this plan was written. Traefik v3.7.13 built for both architectures, the registry unit tests passed inside the build, the smoke test passed 10/10 against the built image and failed 7 checks against stock `traefik:v3.7.13`, the updater tests passed, a live updater run bumped real pins correctly, and shellcheck and actionlint were clean. Copy the file contents exactly.

## Global Constraints

- Image name: `ghcr.io/<repository owner, lowercased>/traefik`, i.e. `ghcr.io/tracyhatemice/traefik`. The package name is `traefik`, not the repo name.
- Platforms: `linux/amd64` and `linux/arm64`.
- Plugins, exactly these three. Geoblock is not included.
  - `modsecurity`: repo `github.com/david-garcia-garcia/traefik-modsecurity`, same Go module.
  - `robots-txt`: repo `github.com/solution-libre/traefik-plugin-robots-txt`, same Go module.
  - `captcha-protect`: repo `github.com/tracyhatemice/captcha-protect`, Go module `github.com/libops/captcha-protect`.
- Tracks: `stable-major` | `stable` | `head` | `pinned`. Defaults: Traefik, modsecurity and robots-txt use `stable-major`; captcha-protect uses `head`.
- Pins at plan time:
  - Traefik `v3.7.13`
  - modsecurity `v1.8.1`
  - robots-txt `v0.2.2`
  - captcha-protect `9cd7e2d5866c2bd764d192298a2961c6299d1297`
- Base images: `golang:1.26-alpine` with `GOTOOLCHAIN=auto`, `node:24-alpine`, `alpine:3.24`.
- Action majors: `actions/checkout@v7`, `actions/upload-artifact@v7`, `actions/download-artifact@v8`, `docker/setup-qemu-action@v4`, `docker/setup-buildx-action@v4`, `docker/login-action@v4`, `docker/metadata-action@v6`, `docker/build-push-action@v7`.
- Only `main` publishes. PRs and other refs build and test only. The version-bump commit is pushed only after the image push succeeds.
- Scripts under `scripts/` and `test/` are bash. `build/integrate-plugins.sh` is POSIX sh because it runs in Alpine's busybox. All scripts must be shellcheck-clean and indented with tabs.
- Line endings are LF (`.gitattributes`). Readers of `versions.conf` tolerate CRLF.
- Nothing is pushed to GitHub and no PR is merged without the user's explicit go-ahead (Task 5).

## Review Focus

1. **`versions.conf` hand-edited in a Windows editor from WSL (CRLF).** Every reader must see `v1.8.1`, not `v1.8.1\r`. Covered by `CRLF line endings are tolerated` in Task 1 and the CRLF integrate check in Task 2 Step 7.
2. **A Traefik release moves `Builder.Build` so `builder.patch` no longer applies.** The build must fail rather than ship an image with no embedded plugins. Covered by the patch-anchor check in Task 2 Step 8. The smoke test is a second line of defence.
3. **A plugin listed in `versions.conf` but not imported by `embedded-registry.go`.** The build must fail and name the plugin, instead of `go mod tidy` silently dropping it. Covered by Task 2 Step 7.
4. **A scheduled run where the new upstream version fails to build or test.** `:latest` and `versions.conf` on `main` must stay unchanged, and the run must be red. No automated test covers this. Task 4 Step 3 checks the step ordering and conditions, and optional Task 5 Step 9 exercises the bump loop end to end.
5. **captcha-protect exempts private client IPs.** The smoke test would silently pass the request through if it forgot to present a public IP. Covered by the `302 /challenge` assertion with `X-Forwarded-For: 203.0.113.7` in Task 3. The README documents `ipForwardedHeader` for deployments behind a proxy.

## File Map

| File | Responsibility | Task |
|---|---|---|
| `.gitattributes` | force LF | 1 |
| `versions.conf` | pins and track policy per component | 1 |
| `scripts/update-versions.sh` | move pins forward per track; GitHub outputs | 1 |
| `scripts/update-versions.test.sh` | offline tests for the updater | 1 |
| `build/embedded-registry.go` | plugin key → CreateConfig/New; Yaegi-identical config decoding; key remapping | 2 |
| `build/embedded_registry_test.go` | registry unit tests, run inside the Docker build | 2 |
| `build/builder.patch` | make Traefik's `Builder.Build` consult the registry first | 2 |
| `build/integrate-plugins.sh` | fetch each plugin at its pin; `go mod` require + replace; fail on unregistered plugins | 2 |
| `build/Dockerfile` | source → webui → builder (cross-compile) → runtime | 2 |
| `build/NOTICE` | MIT notice for the adapted reference files | 2 |
| `.dockerignore` | send only `versions.conf` and `build/` as build context | 2 |
| `test/smoke/traefik.yml`, `dynamic.yml`, `compose.yaml`, `run.sh` | end-to-end check that each plugin loads and works | 3 |
| `.github/workflows/build.yml` | test, check upstream, build, smoke test, publish, commit bump | 4 |
| `README.md` | usage, tags, update policy, maintenance | 4 |

---

### Task 1: Baseline commit, `versions.conf` and the updater

**Files:**
- Create: `.gitattributes`
- Create: `scripts/update-versions.test.sh`
- Create: `scripts/update-versions.sh`
- Create: `versions.conf`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `versions.conf` keys `<PREFIX>_REPO`, `<PREFIX>_VERSION` and `<PREFIX>_TRACK`, where `<PREFIX>` is `TRAEFIK` or `PLUGIN_<NAME>` with `NAME` matching `[A-Z0-9_]+`.
  - `scripts/update-versions.sh [versions.conf]` prints `<PREFIX>_VERSION <old> -> <new>` per change and exits non-zero on error with the file untouched.
  - Under Actions, the script writes `changed=true|false` and a multi-line `changes` block to `$GITHUB_OUTPUT`.
  - Sourcing the script defines `pick_tag`, `semver_gt`, `next_version`, `conf_get`, `conf_set`, `update_versions`, `main`, `remote_tags` and `remote_head` without running anything.

- [ ] **Step 1: Commit the docs on `main`, then branch**

The repo has no commits. Put the approved docs on `main` first, so that pushing the feature branch later doesn't make GitHub pick it as the default branch.

Create `.gitattributes`:

````text
* text=auto eol=lf
````

```bash
cd /home/ubuntu/project/traefik-with-plugins
git add .gitattributes docs/superpowers/specs/2026-09-24-traefik-with-plugins-design.md docs/superpowers/plans/2026-09-24-traefik-with-plugins.md
git commit -m "docs: design spec and implementation plan"
git switch -c build-pipeline
```

Expected: one commit on `main`; now on branch `build-pipeline`.

- [ ] **Step 2: Write the failing updater test**

Create `scripts/update-versions.test.sh`:

````bash
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
````

- [ ] **Step 3: Run it to verify it fails**

```bash
chmod +x scripts/update-versions.test.sh
scripts/update-versions.test.sh
```

Expected: `scripts/update-versions.sh: No such file or directory`, then `pick_tag: command not found` and `FAIL` lines. It ends with `<N> test(s) failed` and exits non-zero.

- [ ] **Step 4: Write the updater**

Create `scripts/update-versions.sh`:

````bash
#!/usr/bin/env bash
# Move every component in versions.conf to the newest upstream version its
# <PREFIX>_TRACK allows (see the header of versions.conf).
#
# usage: scripts/update-versions.sh [versions.conf]
#
# Prints one "<PREFIX>_VERSION <old> -> <new>" line per change. Under GitHub
# Actions it also writes changed=true|false and the change lines (as
# "changes") to $GITHUB_OUTPUT, and a table to $GITHUB_STEP_SUMMARY.
# On any error it exits non-zero and leaves versions.conf untouched.

semver_re='^v?([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'

# semver_gt <a> <b>: whether semver a is newer than b. Only ever called with a
# stable <a>, so a prerelease <b> loses to an <a> with the same core version.
semver_gt() {
	[[ $1 =~ $semver_re ]] || return 1
	local a=("${BASH_REMATCH[@]:1:4}")
	[[ $2 =~ $semver_re ]] || return 1
	local b=("${BASH_REMATCH[@]:1:4}")
	local i
	for i in 0 1 2; do
		((10#${a[i]} > 10#${b[i]})) && return 0
		((10#${a[i]} < 10#${b[i]})) && return 1
	done
	[[ -z ${a[3]} && -n ${b[3]} ]]
}

# pick_tag <track> <current>: read tag names on stdin, print the version to
# use: the newest stable tag allowed by <track> if newer than <current>,
# otherwise <current>.
pick_tag() {
	local track=$1 current=$2 major="" best=$2 tag
	if [[ $track == stable-major ]]; then
		if [[ $current =~ $semver_re ]]; then
			major=$((10#${BASH_REMATCH[1]}))
		else
			echo "warning: $current is not a semver tag; stable-major behaves like stable" >&2
		fi
	fi
	while IFS= read -r tag; do
		[[ $tag =~ $semver_re ]] || continue
		[[ -z ${BASH_REMATCH[4]} ]] || continue # prerelease
		[[ -z $major || $((10#${BASH_REMATCH[1]})) == "$major" ]] || continue
		if [[ ! $best =~ $semver_re ]] || semver_gt "$tag" "$best"; then
			best=$tag
		fi
	done
	echo "$best"
}

# Remote lookups; the tests replace these.
remote_tags() { git ls-remote --tags --refs "https://$1.git" | sed 's#.*refs/tags/##'; }
remote_head() { git ls-remote "https://$1.git" HEAD | cut -f1; }

# next_version <track> <repo> <current>
next_version() {
	local track=$1 repo=$2 current=$3 tags sha
	case $track in
	pinned) echo "$current" ;;
	head)
		sha=$(remote_head "$repo") || return 1
		[[ $sha =~ ^[0-9a-f]{40}$ ]] || {
			echo "error: cannot resolve HEAD of $repo (got '$sha')" >&2
			return 1
		}
		echo "$sha"
		;;
	stable | stable-major)
		tags=$(remote_tags "$repo") || {
			echo "error: cannot list tags of $repo" >&2
			return 1
		}
		pick_tag "$track" "$current" <<<"$tags"
		;;
	*)
		echo "error: unknown track '$track' for $repo (use stable-major, stable, head or pinned)" >&2
		return 1
		;;
	esac
}

# conf_get <file> <key>: last value of <key>, ignoring CRLF line endings.
conf_get() { sed -n "s/^$2=//p" "$1" | tail -n 1 | tr -d '\r'; }

# conf_set <file> <key> <value>, keeping every other line (and the file's mode).
conf_set() {
	local out
	out=$(awk -v k="$2" -v v="$3" 'index($0, k "=") == 1 { $0 = k "=" v } { print }' "$1") || return 1
	printf '%s\n' "$out" >"$1"
}

# update_versions <file>: rewrite <file> in place, print one line per change.
update_versions() {
	local conf=$1 prefixes prefix repo version track next
	prefixes=$(sed -n -E 's/^(TRAEFIK|PLUGIN_[A-Z0-9_]+)_REPO=.*/\1/p' "$conf")
	[[ -n $prefixes ]] || {
		echo "error: no TRAEFIK_REPO or PLUGIN_*_REPO entries in $conf" >&2
		return 1
	}
	for prefix in $prefixes; do
		repo=$(conf_get "$conf" "${prefix}_REPO")
		version=$(conf_get "$conf" "${prefix}_VERSION")
		track=$(conf_get "$conf" "${prefix}_TRACK")
		[[ -n $version && -n $track ]] || {
			echo "error: ${prefix}_VERSION and ${prefix}_TRACK must be set" >&2
			return 1
		}
		next=$(next_version "$track" "$repo" "$version") || return 1
		if [[ $next != "$version" ]]; then
			conf_set "$conf" "${prefix}_VERSION" "$next" || return 1
			echo "${prefix}_VERSION $version -> $next"
		fi
	done
}

# main runs in a subshell so the tests can call it without inheriting its
# traps or shell options. Errors are handled explicitly because set -e is
# ignored when a caller tests main's status (if main ...; then).
main() (
	set -uo pipefail
	conf=${1:-versions.conf}
	work=$(mktemp) || exit 1
	trap 'rm -f "$work"' EXIT

	cp "$conf" "$work" || exit 1
	changes=$(update_versions "$work") || exit 1
	cat "$work" >"$conf" || exit 1

	[[ -z $changes ]] || echo "$changes"

	if [[ -n ${GITHUB_OUTPUT:-} ]]; then
		echo "changed=$([[ -n $changes ]] && echo true || echo false)"
		echo "changes<<CHANGES_EOF"
		echo "$changes"
		echo "CHANGES_EOF"
	fi >>"${GITHUB_OUTPUT:-/dev/null}"

	if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
		if [[ -n $changes ]]; then
			echo "### Upstream updates"
			echo "| Version | From | To |"
			echo "|---|---|---|"
			while read -r key old _ new; do
				echo "| \`$key\` | \`$old\` | \`$new\` |"
			done <<<"$changes"
		else
			echo "No upstream updates."
		fi
	fi >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
````

Notes for the implementer:
- `main` is a subshell function (`main() ( … )`), so its trap and `exit` stay contained when the tests call it.
- `set -e` is not used for control flow. Bash ignores it inside `if main …`, so every failure path uses an explicit `|| return 1` or `|| exit 1`.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
chmod +x scripts/update-versions.sh
scripts/update-versions.test.sh
```

Expected: 30 `ok` lines, ending in `all updater tests passed`, exit 0.

- [ ] **Step 6: Write `versions.conf`**

````text
# Versions baked into the image. Sourced by shell scripts and read by the
# Docker build; rewritten by scripts/update-versions.sh.
#
# Each component has <PREFIX>_REPO, <PREFIX>_VERSION and <PREFIX>_TRACK.
# TRACK is one of:
#   stable-major  newest stable tag with the same major as VERSION
#   stable        newest stable tag, any major
#   head          latest commit on the repo's default branch (VERSION is a SHA)
#   pinned        never updated automatically
# Plugins are every PLUGIN_<NAME>_REPO entry; each must also be registered in
# build/embedded-registry.go.

TRAEFIK_REPO=github.com/traefik/traefik
TRAEFIK_VERSION=v3.7.13
TRAEFIK_TRACK=stable-major

PLUGIN_MODSECURITY_REPO=github.com/david-garcia-garcia/traefik-modsecurity
PLUGIN_MODSECURITY_VERSION=v1.8.1
PLUGIN_MODSECURITY_TRACK=stable-major

PLUGIN_ROBOTS_TXT_REPO=github.com/solution-libre/traefik-plugin-robots-txt
PLUGIN_ROBOTS_TXT_VERSION=v0.2.2
PLUGIN_ROBOTS_TXT_TRACK=stable-major

PLUGIN_CAPTCHA_PROTECT_REPO=github.com/tracyhatemice/captcha-protect
PLUGIN_CAPTCHA_PROTECT_VERSION=9cd7e2d5866c2bd764d192298a2961c6299d1297
PLUGIN_CAPTCHA_PROTECT_TRACK=head
````

Check that the pins are current:

```bash
live=$(mktemp); cp versions.conf "$live"
scripts/update-versions.sh "$live"; echo "exit=$?"
```

Expected: exit 0. It normally prints nothing. If upstream has moved since 2026-09-24 it prints a bump line; copy the new values into `versions.conf`. The captcha fork's HEAD moves whenever its `main` does.

- [ ] **Step 7: Live check against the real upstreams**

```bash
conf=$(mktemp)
sed 's/^TRAEFIK_VERSION=.*/TRAEFIK_VERSION=v3.6.25/; s/^PLUGIN_MODSECURITY_VERSION=.*/PLUGIN_MODSECURITY_VERSION=v1.7.5/' versions.conf >"$conf"
scripts/update-versions.sh "$conf"
```

Expected (or newer versions):
```
TRAEFIK_VERSION v3.6.25 -> v3.7.13
PLUGIN_MODSECURITY_VERSION v1.7.5 -> v1.8.1
```

- [ ] **Step 8: Lint**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/update-versions.sh scripts/update-versions.test.sh
```

Expected: no output, exit 0.

- [ ] **Step 9: Commit**

```bash
git add versions.conf scripts/update-versions.sh scripts/update-versions.test.sh
git commit -m "Add versions.conf and the upstream version updater"
```

---

### Task 2: Embedded registry and the image build

**Files:**
- Create: `build/embedded_registry_test.go`
- Create: `build/embedded-registry.go`
- Create: `build/builder.patch`
- Create: `build/integrate-plugins.sh`
- Create: `build/Dockerfile`
- Create: `build/NOTICE`
- Create: `.dockerignore`

**Interfaces:**
- Consumes: `versions.conf` keys from Task 1.
- Produces:
  - An image whose `/traefik` binary has the plugin keys `modsecurity`, `robots-txt` and `captcha-protect` built in.
  - Build args `TRAEFIK_REPO` and `TRAEFIK_VERSION`, which must equal `versions.conf`.
  - Build context: repo root. Dockerfile path: `build/Dockerfile`.
  - Go, copied into Traefik's `package plugins`:
    - `IsEmbeddedPlugin(name string) bool`
    - `BuildEmbeddedPlugin(ctx, pluginName string, config map[string]any, middlewareName string) (Constructor, error)`
    - `buildPluginRegistry(getenv func(string) string) map[string]embeddedPlugin`
    - `registryKeys(map[string]embeddedPlugin) []string`, which returns sorted keys.

- [ ] **Step 1: Write the registry unit test**

These tests compile only inside Traefik's `pkg/plugins`. The Dockerfile copies them there and runs them during the build (Step 6).

Create `build/embedded_registry_test.go`:

````go
package plugins

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
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
````

- [ ] **Step 2: Write the registry**

Create `build/embedded-registry.go`:

````go
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

	modsecurity "github.com/david-garcia-garcia/traefik-modsecurity"
	captcha "github.com/libops/captcha-protect"
	robotstxt "github.com/solution-libre/traefik-plugin-robots-txt"
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
````

Check formatting (the file is compiled inside Traefik, so gofmt is the local check):

```bash
gofmt -l build/
```

Expected: no output. If Go isn't installed locally, use `docker run --rm -v "$PWD:/w" -w /w golang:1.26-alpine gofmt -l build/`.

- [ ] **Step 3: Write the builder patch**

Create `build/builder.patch`. It is a context diff applied with `patch -p0`; a small line offset is fine, but a rejected hunk fails the build.

````diff
--- pkg/plugins/builder.go
+++ pkg/plugins/builder.go
@@ -111,6 +111,11 @@
 
 // Build builds a middleware plugin.
 func (b Builder) Build(pName string, config map[string]any, middlewareName string) (Constructor, error) {
+	// First, check if it's an embedded plugin
+	if IsEmbeddedPlugin(pName) {
+		return BuildEmbeddedPlugin(context.Background(), pName, config, middlewareName)
+	}
+
 	if b.middlewareBuilders == nil {
 		return nil, fmt.Errorf("no plugin definitions in the static configuration: %s", pName)
 	}
````

- [ ] **Step 4: Write the plugin integration script**

Create `build/integrate-plugins.sh`:

````sh
#!/bin/sh
# Wire every PLUGIN_<NAME>_* entry of versions.conf into the Traefik module:
# fetch the plugin at its pinned tag or commit, then require + replace its Go
# module with that checkout. Run from the Traefik source root.
#
# usage: integrate-plugins.sh <versions.conf> <plugins-dir> <embedded-registry.go>
set -eu

conf=$1
plugins_dir=$2
registry=$3

get() { sed -n "s/^$1=//p" "$conf" | tail -n 1 | tr -d '\r'; }

names=$(sed -n 's/^PLUGIN_\([A-Z0-9_]*\)_REPO=.*/\1/p' "$conf")
[ -n "$names" ] || { echo "no PLUGIN_*_REPO entries in $conf" >&2; exit 1; }

for name in $names; do
	repo=$(get "PLUGIN_${name}_REPO")
	version=$(get "PLUGIN_${name}_VERSION")
	[ -n "$version" ] || { echo "PLUGIN_${name}_VERSION is empty" >&2; exit 1; }
	dir="$plugins_dir/$(echo "$name" | tr 'A-Z_' 'a-z-')"

	echo "==> $repo @ $version"
	git init -q "$dir"
	git -C "$dir" fetch -q --depth 1 "https://$repo.git" "$version"
	git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD

	module=$(sed -n 's/^module[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$dir/go.mod" | tr -d '\r')
	[ -n "$module" ] || { echo "cannot read module path from $dir/go.mod" >&2; exit 1; }
	grep -q "\"$module\"" "$registry" || {
		echo "$module (PLUGIN_$name) is not imported by $registry; register it there" >&2
		exit 1
	}

	go mod edit -require="$module@v0.0.0-00010101000000-000000000000" -replace="$module=$dir"
done
````

- [ ] **Step 5: Write the Dockerfile, NOTICE and .dockerignore**

Create `build/Dockerfile`:

````dockerfile
# syntax=docker/dockerfile:1

# Traefik with plugins compiled into the binary.
#
# Build from the repo root; TRAEFIK_REPO and TRAEFIK_VERSION must match
# versions.conf (checked below). They are build args rather than read from
# versions.conf so the Traefik checkout and webui build stay cached when only
# a plugin changes.
#
#   . ./versions.conf && docker buildx build -f build/Dockerfile \
#     --build-arg TRAEFIK_REPO=$TRAEFIK_REPO --build-arg TRAEFIK_VERSION=$TRAEFIK_VERSION .

ARG GO_IMAGE=golang:1.26-alpine
ARG NODE_IMAGE=node:24-alpine
ARG RUNTIME_IMAGE=alpine:3.24

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS source
ARG TRAEFIK_REPO
ARG TRAEFIK_VERSION
RUN apk add --no-cache git patch
WORKDIR /src/traefik
RUN test -n "$TRAEFIK_REPO" && test -n "$TRAEFIK_VERSION" \
 && git init -q . \
 && git fetch -q --depth 1 "https://${TRAEFIK_REPO}.git" "${TRAEFIK_VERSION}" \
 && git -c advice.detachedHead=false checkout -q FETCH_HEAD

# The dashboard is architecture-independent: build it once on the build platform.
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS webui
ENV VITE_APP_BASE_URL="" VITE_APP_BASE_API_URL="/api"
WORKDIR /src/webui
COPY --from=source /src/traefik/webui/ ./
RUN corepack enable && yarn install --immutable && yarn build

FROM source AS builder
ARG TRAEFIK_VERSION
# Traefik can require a newer Go than the image ships; let go fetch it.
ENV GOTOOLCHAIN=auto CGO_ENABLED=0
COPY --from=webui /src/webui/static/ webui/static/
COPY versions.conf /tmp/versions.conf
COPY build/builder.patch build/integrate-plugins.sh /tmp/
COPY build/embedded-registry.go build/embedded_registry_test.go pkg/plugins/
RUN conf_version=$(sed -n 's/^TRAEFIK_VERSION=//p' /tmp/versions.conf | tr -d '\r') \
 && [ "$conf_version" = "$TRAEFIK_VERSION" ] \
 || { echo "build arg TRAEFIK_VERSION=$TRAEFIK_VERSION but versions.conf has $conf_version" >&2; exit 1; }
RUN patch -p0 --forward < /tmp/builder.patch
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    sh /tmp/integrate-plugins.sh /tmp/versions.conf /plugins pkg/plugins/embedded-registry.go \
 && go mod tidy \
 && go test ./pkg/plugins/ -run 'Embedded'

ARG TARGETOS
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    pkg=$(go list -m)/pkg/version \
 && codename=$(sed -n 's/^[[:space:]]*CODENAME:[[:space:]]*//p' .github/workflows/release.yaml | head -n 1) \
 && GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -o /out/traefik -ldflags "-s -w \
      -X $pkg.Version=$TRAEFIK_VERSION \
      -X $pkg.Codename=${codename:-cheddar} \
      -X $pkg.BuildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      ./cmd/traefik

FROM ${RUNTIME_IMAGE}
RUN apk add --no-cache --no-progress ca-certificates tzdata
COPY --from=builder /out/traefik /traefik
EXPOSE 80
VOLUME ["/tmp"]
ENTRYPOINT ["/traefik"]
````

Create `build/NOTICE`:

````text
build/embedded-registry.go and build/builder.patch are adapted from
https://github.com/david-garcia-garcia/traefik-with-plugins, used under the
following license:

MIT License

Copyright (c) 2026 David García García

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
````

Create `.dockerignore`:

````text
*
!versions.conf
!build/
````

- [ ] **Step 6: Build amd64 and verify the version and the in-build tests**

```bash
chmod +x build/integrate-plugins.sh
. ./versions.conf
docker buildx build -f build/Dockerfile --platform linux/amd64 \
  --build-arg TRAEFIK_REPO="$TRAEFIK_REPO" --build-arg TRAEFIK_VERSION="$TRAEFIK_VERSION" \
  -t traefik-local:amd64 --load --progress=plain . >"${log:=$(mktemp)}" 2>&1; echo "exit=$?"
grep -E '==> github.com|ok .*github.com/traefik/traefik/v3/pkg/plugins' "$log"
docker run --rm traefik-local:amd64 version
```

Expected:
- `exit=0`. The build takes about 4 minutes cold. On failure, read the end of `$log`.
- The grep shows three `==> github.com/...` lines, one per plugin, and an `ok … github.com/traefik/traefik/v3/pkg/plugins` line from the registry tests.
- `version` prints `Version: v3.7.13`, `Codename: langres` and `OS/Arch: linux/amd64`, plus a real `Built:` timestamp.

- [ ] **Step 7: Verify the integration guards**

The plugin-not-registered guard and CRLF tolerance:

```bash
work=$(mktemp -d); mkdir "$work/mod"; cd "$work/mod"
printf 'module example.com/t\n\ngo 1.26\n' >go.mod
printf 'PLUGIN_ROBOTS_TXT_REPO=github.com/solution-libre/traefik-plugin-robots-txt\r\nPLUGIN_ROBOTS_TXT_VERSION=v0.2.2\r\nPLUGIN_GEOBLOCK_REPO=github.com/david-garcia-garcia/traefik-geoblock\nPLUGIN_GEOBLOCK_VERSION=v1.2.1\n' >../v.conf
sh /home/ubuntu/project/traefik-with-plugins/build/integrate-plugins.sh ../v.conf "$work/plugins" /home/ubuntu/project/traefik-with-plugins/build/embedded-registry.go; echo "exit=$?"
grep -c $'\r' go.mod
cd /home/ubuntu/project/traefik-with-plugins; rm -rf "$work"
```

Expected:
- robots-txt (CRLF entries) is fetched.
- Geoblock is rejected with `github.com/david-garcia-garcia/traefik-geoblock (PLUGIN_GEOBLOCK) is not imported by …; register it there` and `exit=1`.
- `grep -c` prints `0`, meaning no carriage returns leaked into `go.mod`.

- [ ] **Step 8: Verify the patch fails loudly if its anchor disappears**

```bash
repo=$PWD; work=$(mktemp -d); mkdir -p "$work/pkg/plugins"
curl -fsSL "https://raw.githubusercontent.com/traefik/traefik/v3.7.13/pkg/plugins/builder.go" >"$work/pkg/plugins/builder.go"
(cd "$work" && patch -p0 --dry-run <"$repo/build/builder.patch"); echo "clean=$?"
sed -i 's/func (b Builder) Build(/func (b Builder) Construct(/' "$work/pkg/plugins/builder.go"
(cd "$work" && patch -p0 --dry-run <"$repo/build/builder.patch"); echo "moved=$?"
rm -rf "$work"
```

Expected: `clean=0`, then `Hunk #1 FAILED at 111.`, `1 out of 1 hunk FAILED` and `moved=1`.

- [ ] **Step 9: Build arm64 and run it under QEMU**

```bash
docker run --rm --platform linux/arm64 alpine:3.24 uname -m || docker run --privileged --rm tonistiigi/binfmt --install arm64
. ./versions.conf
docker buildx build -f build/Dockerfile --platform linux/arm64 \
  --build-arg TRAEFIK_REPO="$TRAEFIK_REPO" --build-arg TRAEFIK_VERSION="$TRAEFIK_VERSION" \
  -t traefik-local:arm64 --load .
docker run --rm --platform linux/arm64 traefik-local:arm64 version
```

Expected: the source, webui and module stages come from cache, only the `go build` step reruns (about 2 minutes), and `OS/Arch: linux/arm64` is printed.

- [ ] **Step 10: Lint and commit**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable build/integrate-plugins.sh
git add .dockerignore build/
git commit -m "Build Traefik with modsecurity, robots-txt and captcha-protect embedded"
```

Expected: shellcheck prints nothing; one commit.

---

### Task 3: Smoke test

**Files:**
- Create: `test/smoke/traefik.yml`
- Create: `test/smoke/dynamic.yml`
- Create: `test/smoke/compose.yaml`
- Create: `test/smoke/run.sh`

**Interfaces:**
- Consumes: any image tag, passed in `IMAGE`, e.g. `traefik-local:amd64` from Task 2.
- Produces:
  - `IMAGE=<image> test/smoke/run.sh` exits 0 only if all 10 checks pass, and prints `ok   - …` or `FAIL - …` per check.
  - It publishes ports `127.0.0.1:8000` and `127.0.0.1:8080`, which must be free.
  - The workflow in Task 4 calls it as `IMAGE=traefik-smoke:amd64 test/smoke/run.sh`.

Design notes, all found by prototyping:
- **modsecurity fails open.** If the WAF is unreachable, requests pass through, so "router enabled" proves nothing. Its WAF URL therefore points at a second entrypoint, `fakewaf` (:8001), whose only router denies everything, and a protected request must come back `403`.
- **modsecurity rejects WAF URLs that contain a path.** That is why the fake WAF gets its own entrypoint instead of a path on `web`.
- **`web` must be `asDefault: true`.** Otherwise the plugin routers also bind to `fakewaf` and modsecurity's WAF call loops back into itself until it times out.
- **captcha-protect exempts private ranges.** Docker traffic arrives from a 172.x bridge IP, so the test sends `X-Forwarded-For: 203.0.113.7` (TEST-NET-3) and `web` trusts forwarded headers.
- **Traefik's log uses ANSI colours by default.** They hide ` ERR ` from grep, so `log.noColor: true` is set.

- [ ] **Step 1: Write the configs and the runner**

Create `test/smoke/traefik.yml`:

````yaml
# Static config for the smoke test. There is deliberately no
# experimental.plugins section: every plugin that works here is embedded.
entryPoints:
  web:
    address: ":8000"
    asDefault: true
    # Lets run.sh present a public client IP via X-Forwarded-For; captcha-protect
    # exempts private ranges, and Docker requests arrive from a private bridge IP.
    forwardedHeaders:
      insecure: true
  # Stand-in ModSecurity WAF that denies everything (router fake-waf).
  # Not a default entrypoint, so the plugin routers don't loop back into it.
  fakewaf:
    address: ":8001"
  traefik:
    address: ":8080"

api:
  insecure: true
  disableDashboardAd: true

ping: {}

log:
  level: INFO
  noColor: true # run.sh greps for " ERR "

providers:
  file:
    filename: /etc/traefik/dynamic.yml
````

Create `test/smoke/dynamic.yml`:

````yaml
http:
  routers:
    plain:
      rule: PathPrefix(`/plain`)
      service: whoami
    robots:
      rule: Path(`/robots.txt`)
      middlewares: [robots]
      service: whoami
    captcha:
      rule: PathPrefix(`/captcha`)
      middlewares: [captcha]
      service: whoami
    modsecurity:
      rule: PathPrefix(`/modsecurity`)
      middlewares: [modsecurity]
      service: whoami
    fake-waf:
      rule: PathPrefix(`/`)
      entryPoints: [fakewaf]
      middlewares: [deny-all]
      service: whoami

  middlewares:
    robots:
      plugin:
        robots-txt:
          customRules: "User-agent: *\nDisallow: /smoke-test/\n"
          overwrite: true
    captcha:
      plugin:
        captcha-protect:
          protectRoutes: /captcha
          ipForwardedHeader: X-Forwarded-For
          captchaProvider: turnstile
          # Cloudflare's documented always-pass test keys.
          siteKey: 1x00000000000000000000AA
          secretKey: 1x0000000000000000000000000000000AA
          enableCommonCrawlIPCheck: "false"
    modsecurity:
      plugin:
        modsecurity:
          modSecurityUrl: http://127.0.0.1:8001
    deny-all:
      ipAllowList:
        sourceRange: ["192.0.2.1/32"]

  services:
    whoami:
      loadBalancer:
        servers:
          - url: http://whoami:80
````

Create `test/smoke/compose.yaml`:

````yaml
name: traefik-smoke

services:
  traefik:
    image: ${IMAGE:?set IMAGE to the image under test}
    ports:
      - "127.0.0.1:8000:8000"
      - "127.0.0.1:8080:8080"
    volumes:
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./dynamic.yml:/etc/traefik/dynamic.yml:ro

  whoami:
    image: traefik/whoami
````

Create `test/smoke/run.sh`:

````bash
#!/usr/bin/env bash
# Smoke-test an image: Traefik starts, and each embedded plugin loads without
# Yaegi and does its job.
#
# usage: IMAGE=<image> test/smoke/run.sh
set -euo pipefail
cd "$(dirname "$0")"

: "${IMAGE:?set IMAGE to the image under test}"
export IMAGE

web=http://127.0.0.1:8000
api=http://127.0.0.1:8080
failures=0

check() { # check <description> <expected> <actual>
	if [[ "$3" == "$2" ]]; then
		echo "ok   - $1"
	else
		echo "FAIL - $1: expected '$2', got '$3'"
		failures=$((failures + 1))
	fi
}

cleanup() {
	if ((failures > 0)); then
		echo "--- traefik logs ---"
		docker compose logs traefik || true
	fi
	docker compose down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for() { # wait_for <url> <status>
	for _ in $(seq 1 30); do
		[[ "$(curl -s -o /dev/null -w '%{http_code}' "$1")" == "$2" ]] && return 0
		sleep 1
	done
	echo "timed out waiting for $1 to return $2" >&2
	failures=$((failures + 1))
	exit 1
}

docker compose up -d --quiet-pull
wait_for "$api/ping" 200
wait_for "$web/plain" 200 # file provider loaded and whoami is up

routers=$(curl -fsS "$api/api/http/routers")
for r in plain robots captcha modsecurity fake-waf; do
	check "router $r enabled" enabled \
		"$(jq -r --arg n "$r@file" '.[] | select(.name == $n) | .status' <<<"$routers")"
done

robots=$(curl -fsS "$web/robots.txt" || true)
check "robots-txt serves the custom rule" yes \
	"$(grep -qx 'Disallow: /smoke-test/' <<<"$robots" && echo yes || echo no)"

check "captcha-protect redirects to its challenge" "302 /challenge" \
	"$(curl -s -o /dev/null -w '%{http_code} %header{location}' -H 'X-Forwarded-For: 203.0.113.7' \
		"$web/captcha/page" | cut -d'?' -f1)"

check "modsecurity blocks when the WAF denies" 403 \
	"$(curl -s -o /dev/null -w '%{http_code}' "$web/modsecurity/page")"

check "dashboard is embedded" 200 \
	"$(curl -s -o /dev/null -w '%{http_code}' "$api/dashboard/")"

check "no error lines in traefik log" 0 \
	"$(docker compose logs --no-log-prefix traefik 2>&1 | grep -cE ' ERR |level=ERROR' || true)"

if ((failures > 0)); then
	echo "$failures check(s) failed"
	exit 1
fi
echo "all smoke checks passed"
````

- [ ] **Step 2: Run it against stock Traefik to prove it detects missing plugins**

```bash
chmod +x test/smoke/run.sh
IMAGE=traefik:v3.7.13 test/smoke/run.sh 2>&1 | grep -E '^(ok|FAIL|[0-9]+ check)'; echo "exit=${PIPESTATUS[0]}"
```

Expected: `FAIL` for routers robots, captcha and modsecurity (`got 'disabled'`), for robots-txt, captcha-protect and modsecurity behaviour, and for the error-log check. That is `7 check(s) failed` and `exit=1`. The plain and fake-waf routers and the dashboard still pass.

- [ ] **Step 3: Run it against the built image**

```bash
IMAGE=traefik-local:amd64 test/smoke/run.sh 2>&1 | grep -E '^(ok|FAIL|all|[0-9]+ check)'; echo "exit=${PIPESTATUS[0]}"
```

Expected: 10 `ok` lines, `all smoke checks passed`, `exit=0`.

- [ ] **Step 4: Lint and commit**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable test/smoke/run.sh
git add test/smoke/
git commit -m "Add a smoke test proving each embedded plugin loads and works"
```

---

### Task 4: Workflow and README

**Files:**
- Create: `.github/workflows/build.yml`
- Create: `README.md`

**Interfaces:**
- Consumes:
  - From Task 1: `scripts/update-versions.sh` and `scripts/update-versions.test.sh`, plus the `changed` and `changes` outputs.
  - From Task 2: `build/Dockerfile` with its build args.
  - From Task 3: `test/smoke/run.sh`.
- Produces:
  - On `main` pushes, schedule and dispatch: tags `latest`, `<TRAEFIK_VERSION>` and `sha-<short sha>` on `ghcr.io/<owner>/traefik`, for both platforms.
  - A bot commit `Bump <KEY>=<new>, …` when upstream moved.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/build.yml`:

````yaml
name: build

on:
  push:
    branches: [main]
    paths-ignore: ["**.md", "docs/**"]
  pull_request:
  schedule:
    - cron: "23 4 * * *" # daily upstream check
  workflow_dispatch: # check upstream, then rebuild even if nothing changed

permissions:
  contents: read

concurrency:
  group: build-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  check:
    name: Test scripts, check upstream
    runs-on: ubuntu-latest
    outputs:
      build: ${{ steps.decide.outputs.build }}
      changes: ${{ steps.update.outputs.changes }}
    steps:
      - uses: actions/checkout@v7

      - name: Test scripts
        run: |
          scripts/update-versions.test.sh
          shellcheck -x scripts/*.sh test/smoke/run.sh build/integrate-plugins.sh

      - name: Check upstream versions
        id: update
        if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
        run: scripts/update-versions.sh versions.conf

      - name: Decide whether to build
        id: decide
        env:
          EVENT: ${{ github.event_name }}
          CHANGED: ${{ steps.update.outputs.changed }}
        run: |
          if [[ $EVENT == schedule && $CHANGED != true ]]; then
            echo "build=false" >>"$GITHUB_OUTPUT"
            echo "No upstream updates; nothing to build." >>"$GITHUB_STEP_SUMMARY"
          else
            echo "build=true" >>"$GITHUB_OUTPUT"
          fi

      - name: Hand versions.conf to the build job
        if: steps.decide.outputs.build == 'true'
        uses: actions/upload-artifact@v7
        with:
          name: versions
          path: versions.conf
          retention-days: 1

  build:
    name: Build, test, publish
    needs: check
    if: needs.check.outputs.build == 'true'
    runs-on: ubuntu-latest
    timeout-minutes: 90
    permissions:
      contents: write # push the versions.conf bump
      packages: write # push to GHCR
    env:
      # Only main publishes; PRs and other branches build and test.
      PUBLISH: ${{ github.event_name != 'pull_request' && github.ref == 'refs/heads/main' }}
    steps:
      - uses: actions/checkout@v7

      - name: Apply upstream updates
        uses: actions/download-artifact@v8
        with:
          name: versions
          path: .

      - name: Commit version bump locally
        id: commit
        env:
          CHANGES: ${{ needs.check.outputs.changes }}
        run: |
          if ! git diff --quiet -- versions.conf; then
            subject=""
            while read -r key _ _ new; do
              [[ $new =~ ^[0-9a-f]{40}$ ]] && new=${new:0:7}
              subject+="${key%_VERSION}=$new, "
            done <<<"$CHANGES"
            git config user.name "github-actions[bot]"
            git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
            printf 'Bump %s\n\n%s\n' "${subject%, }" "$CHANGES" | git commit -q -F - versions.conf
            echo "bumped=true" >>"$GITHUB_OUTPUT"
          fi
          echo "sha=$(git rev-parse --short HEAD)" >>"$GITHUB_OUTPUT"

      - name: Read versions
        id: versions
        run: |
          # shellcheck disable=SC1091
          . ./versions.conf
          owner=${GITHUB_REPOSITORY_OWNER,,}
          plugins=$(sed -n -E 's/^PLUGIN_([A-Z0-9_]+)_REPO=.*/\1/p' versions.conf)
          {
            echo "traefik_repo=$TRAEFIK_REPO"
            echo "traefik_version=$TRAEFIK_VERSION"
            echo "image=ghcr.io/$owner/traefik"
            echo "labels<<LABELS_EOF"
            for name in $plugins; do
              repo_var=PLUGIN_${name}_REPO
              version_var=PLUGIN_${name}_VERSION
              echo "io.github.$owner.traefik.plugin.$(tr 'A-Z_' 'a-z-' <<<"$name")=${!repo_var}@${!version_var}"
            done
            echo "LABELS_EOF"
          } >>"$GITHUB_OUTPUT"
          {
            echo "### Components"
            echo "| Component | Repo | Version |"
            echo "|---|---|---|"
            echo "| traefik | $TRAEFIK_REPO | \`$TRAEFIK_VERSION\` |"
            for name in $plugins; do
              repo_var=PLUGIN_${name}_REPO
              version_var=PLUGIN_${name}_VERSION
              echo "| $(tr 'A-Z_' 'a-z-' <<<"$name") | ${!repo_var} | \`${!version_var}\` |"
            done
          } >>"$GITHUB_STEP_SUMMARY"

      - uses: docker/setup-qemu-action@v4
        with:
          platforms: arm64

      - uses: docker/setup-buildx-action@v4

      - name: Image metadata
        id: meta
        uses: docker/metadata-action@v6
        with:
          images: ${{ steps.versions.outputs.image }}
          tags: |
            type=raw,value=latest
            type=raw,value=${{ steps.versions.outputs.traefik_version }}
            type=raw,value=sha-${{ steps.commit.outputs.sha }}
          labels: |
            org.opencontainers.image.title=traefik
            org.opencontainers.image.description=Traefik with modsecurity, robots-txt and captcha-protect compiled in
            org.opencontainers.image.version=${{ steps.versions.outputs.traefik_version }}
            ${{ steps.versions.outputs.labels }}

      - name: Build amd64 for testing
        uses: docker/build-push-action@v7
        with:
          context: .
          file: build/Dockerfile
          platforms: linux/amd64
          build-args: |
            TRAEFIK_REPO=${{ steps.versions.outputs.traefik_repo }}
            TRAEFIK_VERSION=${{ steps.versions.outputs.traefik_version }}
          load: true
          tags: traefik-smoke:amd64
          cache-from: type=gha

      - name: Smoke test (amd64)
        run: IMAGE=traefik-smoke:amd64 test/smoke/run.sh

      - name: Build arm64 for testing
        uses: docker/build-push-action@v7
        with:
          context: .
          file: build/Dockerfile
          platforms: linux/arm64
          build-args: |
            TRAEFIK_REPO=${{ steps.versions.outputs.traefik_repo }}
            TRAEFIK_VERSION=${{ steps.versions.outputs.traefik_version }}
          load: true
          tags: traefik-smoke:arm64
          cache-from: type=gha

      - name: Run the arm64 binary under QEMU
        run: |
          out=$(docker run --rm --platform linux/arm64 traefik-smoke:arm64 version)
          echo "$out"
          grep -q 'linux/arm64' <<<"$out"

      - name: Log in to GHCR
        if: env.PUBLISH == 'true'
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.repository_owner }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push both platforms
        if: env.PUBLISH == 'true'
        uses: docker/build-push-action@v7
        with:
          context: .
          file: build/Dockerfile
          platforms: linux/amd64,linux/arm64
          build-args: |
            TRAEFIK_REPO=${{ steps.versions.outputs.traefik_repo }}
            TRAEFIK_VERSION=${{ steps.versions.outputs.traefik_version }}
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Push version bump
        if: env.PUBLISH == 'true' && steps.commit.outputs.bumped == 'true'
        run: git push origin HEAD:main

      - name: Summary
        if: env.PUBLISH == 'true'
        env:
          TAGS: ${{ steps.meta.outputs.tags }}
          PUBLISHED: ${{ steps.versions.outputs.image }}:sha-${{ steps.commit.outputs.sha }}
        run: |
          {
            echo "### Published"
            echo '```'
            echo "$TAGS"
            echo
            docker buildx imagetools inspect "$PUBLISHED"
            echo '```'
          } | tee -a "$GITHUB_STEP_SUMMARY"
````

- [ ] **Step 2: Lint it**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -no-color .github/workflows/build.yml; echo "exit=$?"
```

Expected: `exit=0`. The actionlint image bundles shellcheck, so the `run:` blocks are checked too.

- [ ] **Step 3: Check the failure-safety ordering (Review Focus 4)**

Read the `build` job and confirm each of these by line:
1. "Build and push both platforms" comes after "Smoke test (amd64)" and "Run the arm64 binary under QEMU".
2. "Push version bump" comes after "Build and push both platforms".
3. None of the publish steps use `always()` or `continue-on-error`, so any earlier failure skips them.
4. `PUBLISH` is false for `pull_request` and for any ref other than `refs/heads/main`.

- [ ] **Step 4: Dry-run the two inline scripts with sample data**

```bash
CHANGES=$'TRAEFIK_VERSION v3.7.12 -> v3.7.13\nPLUGIN_CAPTCHA_PROTECT_VERSION 0000000000000000000000000000000000000000 -> 9cd7e2d5866c2bd764d192298a2961c6299d1297' bash -c '
subject=""
while read -r key _ _ new; do
  [[ $new =~ ^[0-9a-f]{40}$ ]] && new=${new:0:7}
  subject+="${key%_VERSION}=$new, "
done <<<"$CHANGES"
printf "Bump %s\n" "${subject%, }"'
GITHUB_REPOSITORY_OWNER=TracyHateMice bash -c '
. ./versions.conf; owner=${GITHUB_REPOSITORY_OWNER,,}
for name in $(sed -n -E "s/^PLUGIN_([A-Z0-9_]+)_REPO=.*/\1/p" versions.conf); do
  repo_var=PLUGIN_${name}_REPO; version_var=PLUGIN_${name}_VERSION
  echo "io.github.$owner.traefik.plugin.$(tr "A-Z_" "a-z-" <<<"$name")=${!repo_var}@${!version_var}"
done'
```

Expected:
```
Bump TRAEFIK=v3.7.13, PLUGIN_CAPTCHA_PROTECT=9cd7e2d
io.github.tracyhatemice.traefik.plugin.modsecurity=github.com/david-garcia-garcia/traefik-modsecurity@v1.8.1
io.github.tracyhatemice.traefik.plugin.robots-txt=github.com/solution-libre/traefik-plugin-robots-txt@v0.2.2
io.github.tracyhatemice.traefik.plugin.captcha-protect=github.com/tracyhatemice/captcha-protect@9cd7e2d5866c2bd764d192298a2961c6299d1297
```

- [ ] **Step 5: Write the README**

Create `README.md`:

````markdown
# traefik with embedded plugins

Traefik with three middleware plugins compiled into the binary instead of
loaded through Yaegi, rebuilt automatically when Traefik or a plugin releases.

```
ghcr.io/tracyhatemice/traefik    linux/amd64, linux/arm64
```

| Plugin key | Source | Follows |
|---|---|---|
| `modsecurity` | [david-garcia-garcia/traefik-modsecurity](https://github.com/david-garcia-garcia/traefik-modsecurity) | stable releases, same major |
| `robots-txt` | [solution-libre/traefik-plugin-robots-txt](https://github.com/solution-libre/traefik-plugin-robots-txt) | stable releases, same major |
| `captcha-protect` | [tracyhatemice/captcha-protect](https://github.com/tracyhatemice/captcha-protect) (fork of libops/captcha-protect) | every commit on `main` |

Traefik itself follows stable v3 releases. The exact versions in an image are
in [`versions.conf`](versions.conf) at the commit it was built from, in the
image labels (`docker inspect`), and in the workflow run summary.

## Tags

- `latest`
- the Traefik version, e.g. `v3.7.13`. Moves when a plugin updates under the
  same Traefik release.
- `sha-<commit>`, immutable. Pin this (or a digest) in production.

## Using it

Remove the `experimental.plugins` entries for these plugins from Traefik's
static configuration. Middleware definitions stay the same:

```yaml
http:
  middlewares:
    waf:
      plugin:
        modsecurity:
          modSecurityUrl: http://waf:8080
    robots:
      plugin:
        robots-txt:
          aiRobotsTxt: true
    captcha:
      plugin:
        captcha-protect:
          protectRoutes: /
          captchaProvider: turnstile
          siteKey: <site key>
          secretKey: <secret key>
```

or as labels, e.g.
`traefik.http.middlewares.captcha.plugin.captcha-protect.protectRoutes=/`.

captcha-protect never challenges private addresses (127/8, 10/8, 172.16/12,
192.168/16, fc00::/8). If Traefik sits behind another proxy or load balancer,
set `ipForwardedHeader` (and `ipDepth`) so it sees the real client IP.

To use a different plugin key, set `TRAEFIK_EMBEDDED_<KEY>_KEY` on the
container, with the default key uppercased and `-` replaced by `_`:

```yaml
environment:
  TRAEFIK_EMBEDDED_CAPTCHA_PROTECT_KEY: captcha # plugin.captcha instead of plugin.captcha-protect
```

The package is private because this repository is. Pull with
`docker login ghcr.io` using a personal access token with `read:packages`, or
make the package public under the package's settings.

## How updates work

[`versions.conf`](versions.conf) pins every component. Each has a `_TRACK`:

| Track | Follows |
|---|---|
| `stable-major` | newest stable tag with the same major version as the pin |
| `stable` | newest stable tag, any major |
| `head` | latest commit on the default branch (the pin is a commit SHA) |
| `pinned` | nothing; never changed automatically |

Every day at 04:23 UTC the [build workflow](.github/workflows/build.yml) checks
upstream. If anything moved, it builds both architectures, runs the smoke test,
pushes the image, and only then commits the new `versions.conf` to `main`. If
the new version fails to build or test, the run fails, `latest` stays as it
was, and the next day's run tries again. To stop the retries, set that
component's track to `pinned` or fix the build.

Upgrades across a major version (Traefik v4, a plugin's v2) are deliberate:
edit the version in `versions.conf` and push. Every push to `main` is built,
tested and published.

To rebuild on demand, for example to pick up Alpine security fixes, run the
workflow from the Actions tab or with `gh workflow run build.yml`.

## Adding a plugin

1. Add `PLUGIN_<NAME>_REPO`, `_VERSION` and `_TRACK` to `versions.conf`.
2. Register it in [`build/embedded-registry.go`](build/embedded-registry.go):
   import its Go module and add a `basePluginRegistry` entry. The build fails
   if a plugin in `versions.conf` is not imported there. Add its key to
   `TestEmbeddedRegistryDefaultKeys` in `build/embedded_registry_test.go`.
3. Add a router and a check for it to [`test/smoke/`](test/smoke/).

## Building and testing locally

```sh
. ./versions.conf
docker buildx build -f build/Dockerfile \
  --build-arg TRAEFIK_REPO="$TRAEFIK_REPO" --build-arg TRAEFIK_VERSION="$TRAEFIK_VERSION" \
  -t traefik-local --load .
IMAGE=traefik-local test/smoke/run.sh
scripts/update-versions.test.sh
```

## Repository settings

- The workflow creates the `traefik` package on its first push. If a package
  with that name already exists under the account and isn't linked to this
  repository, give this repository write access under the package's "Manage
  Actions access" settings.
- If branch protection is added to `main`, allow GitHub Actions to push, or the
  daily version bump commit fails.

## Credits

The embedded-plugin approach, registry and builder patch are adapted from
[david-garcia-garcia/traefik-with-plugins](https://github.com/david-garcia-garcia/traefik-with-plugins)
(MIT, see [`build/NOTICE`](build/NOTICE)).
````

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/build.yml README.md
git commit -m "Add the build workflow and README"
```

---

### Task 5: Publish and verify on GitHub (needs the user's go-ahead)

**Files:** none; this task only touches GitHub.

**Interfaces:**
- Consumes: branch `build-pipeline` with Tasks 1–4, and `main` with the docs commit.
- Produces: a merged PR, the published image, and a verified dispatch run.

- [ ] **Step 1: Ask the user before anything leaves the machine**

Show `git log --oneline main build-pipeline` and ask for the go-ahead to push `main` and `build-pipeline` and open a PR. Stop until the user says yes.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin main
git push -u origin build-pipeline
gh pr create --base main --head build-pipeline \
  --title "Build Traefik with embedded plugins" \
  --body "Builds Traefik with modsecurity, robots-txt and captcha-protect compiled in, for linux/amd64 and linux/arm64, published as ghcr.io/tracyhatemice/traefik. A daily check rebuilds when Traefik or a plugin releases. This PR run only builds and tests; publishing happens from main."
```

- [ ] **Step 3: Watch the PR run**

```bash
gh pr checks build-pipeline --watch
```

Expected: `Test scripts, check upstream` and `Build, test, publish` both pass. The first run takes about 15–25 minutes with a cold cache.

Then confirm the run built and tested but did not publish:

```bash
run=$(gh run list --branch build-pipeline --workflow build.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run view "$run" --log | grep -E 'all smoke checks passed|OS/Arch: +linux/arm64'
gh run view "$run" --json jobs --jq '.jobs[] | select(.name=="Build, test, publish") | .steps[] | select(.name|test("GHCR|push|bump")) | "\(.name): \(.conclusion)"'
```

Expected:
- The log contains `all smoke checks passed` and `OS/Arch:      linux/arm64`.
- "Log in to GHCR", "Build and push both platforms" and "Push version bump" are all `skipped`.

If the run fails, use superpowers:systematic-debugging. Do not change tests to make them pass.

- [ ] **Step 4: Ask the user to approve the merge**

This merge publishes the first image. Stop until the user says yes.

- [ ] **Step 5: Merge and watch the publishing run**

```bash
gh pr merge build-pipeline --merge --delete-branch
sleep 10
run=$(gh run list --branch main --workflow build.yml --event push --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$run" --exit-status
```

Expected: success.

- [ ] **Step 6: Verify what was published**

```bash
gh run view "$run" --log | grep -E 'ghcr.io/tracyhatemice/traefik:|Platform: +linux/(amd64|arm64)'
```

Expected:
- Three tags: `ghcr.io/tracyhatemice/traefik:latest`, `:v3.7.13` and `:sha-<7 chars>`.
- `Platform:    linux/amd64` and `Platform:    linux/arm64` from the `imagetools inspect` output.

- [ ] **Step 7: Verify the dispatch path**

```bash
git switch main && git pull
gh workflow run build.yml --ref main
sleep 10
run=$(gh run list --branch main --workflow build.yml --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$run" --exit-status
git fetch && git log --oneline -1 origin/main
```

Expected:
- The run succeeds and republishes, with most layers served from the GHA cache.
- The `check` summary says "No upstream updates.", unless something upstream moved, in which case there is a `Bump …` commit on `origin/main` from `github-actions[bot]`.

- [ ] **Step 8: Report to the user**

Tell the user:
- where the image is, and its tags;
- that the package is private and how to pull it (README "Using it");
- how the daily check works.

- [ ] **Step 9 (optional, only if the user wants the full bump loop exercised, which costs 2 extra builds): simulate an upstream release**

```bash
sed -i 's/^PLUGIN_ROBOTS_TXT_VERSION=.*/PLUGIN_ROBOTS_TXT_VERSION=v0.2.1/' versions.conf
git commit -am "Test: pin robots-txt back to v0.2.1" && git push   # publishes with v0.2.1
gh run watch "$(gh run list --branch main --workflow build.yml --event push --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
gh workflow run build.yml --ref main
sleep 10
gh run watch "$(gh run list --branch main --workflow build.yml --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
git pull && git log --oneline -1
```

Expected: the last commit is `Bump PLUGIN_ROBOTS_TXT=v0.2.2` by `github-actions[bot]`, and `versions.conf` is back at `v0.2.2`.
