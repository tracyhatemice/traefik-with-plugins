#!/bin/sh
# Wire every PLUGIN_<NAME>_* entry of versions.conf into the Traefik module and
# collect its license. Each plugin is fetched with `go get <module>@<version>`
# through the Go module proxy, so go.sum is checked against the checksum
# database; <version> may be a tag or a commit SHA. PLUGIN_<NAME>_REPO must be
# the plugin's Go module path, and the embedded registry must import it.
# Run from the Traefik source root.
#
# usage: integrate-plugins.sh <versions.conf> <embedded-registry.go> <licenses-dir>
set -eu

conf=$1
registry=$2
licenses=$3

get() { sed -n "s/^$1=//p" "$conf" | tail -n 1 | tr -d '\r'; }

names=$(sed -n 's/^PLUGIN_\([A-Z0-9_]*\)_REPO=.*/\1/p' "$conf")
[ -n "$names" ] || { echo "no PLUGIN_*_REPO entries in $conf" >&2; exit 1; }

for name in $names; do
	module=$(get "PLUGIN_${name}_REPO")
	version=$(get "PLUGIN_${name}_VERSION")
	[ -n "$version" ] || { echo "PLUGIN_${name}_VERSION is empty" >&2; exit 1; }
	grep -qF "\"$module\"" "$registry" || {
		echo "$module (PLUGIN_$name) is not imported by $registry; register it there" >&2
		exit 1
	}

	echo "==> $module @ $version"
	go get "$module@$version"

	dir=$(go list -m -f '{{.Dir}}' "$module")
	dest="$licenses/$(echo "$name" | tr 'A-Z_' 'a-z-')"
	mkdir -p "$dest"
	found=0
	for f in "$dir"/LICENSE* "$dir"/LICENCE* "$dir"/COPYING*; do
		[ -f "$f" ] && cp "$f" "$dest/" && found=1
	done
	[ "$found" = 1 ] || { echo "no license file in $module@$version" >&2; exit 1; }
done
