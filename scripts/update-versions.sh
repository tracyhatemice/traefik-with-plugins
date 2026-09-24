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
