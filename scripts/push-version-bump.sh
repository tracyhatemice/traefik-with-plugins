#!/usr/bin/env bash
# Push the local version-bump commit (HEAD) to <branch> on origin.
#
# If <branch> moved while this run was building, the push is rejected and the
# script steps aside: every run on main checks upstream first, so the run
# queued for the newer commit makes the same bump on top of it. Any other
# rejection is an error.
#
# usage: scripts/push-version-bump.sh [branch]
set -euo pipefail

branch=${1:-main}

if git push origin "HEAD:refs/heads/$branch"; then
	exit 0
fi

git fetch --quiet origin "$branch"
if git merge-base --is-ancestor FETCH_HEAD HEAD; then
	echo "error: pushing the version bump to $branch failed" >&2
	exit 1
fi
echo "::notice::$branch moved while this run was building; the run for the newer commit applies the version bump."
