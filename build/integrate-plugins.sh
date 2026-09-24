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
	grep -qF "\"$module\"" "$registry" || {
		echo "$module (PLUGIN_$name) is not imported by $registry; register it there" >&2
		exit 1
	}

	go mod edit -require="$module@v0.0.0-00010101000000-000000000000" -replace="$module=$dir"
done
