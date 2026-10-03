#!/usr/bin/env bash
# Prints the next release tag (e.g. "0.3.2"): the last X.Y.Z tag reachable from HEAD with
# its patch bumped. Prints nothing if HEAD is already tagged, or if nothing has landed since
# the last tag — either way there is nothing new to release.
#
# Every merge is a point release. A minor or major bump is a deliberate call: push that
# tag yourself (`git tag 0.4.0 && git push origin 0.4.0`) and the next merge counts from it.
#
# No "v" prefix: SwiftPM resolves `from: "0.3.1"` against tags spelled exactly that way.
set -euo pipefail

if [ -n "$(git tag --points-at HEAD)" ]; then
  exit 0
fi

# Only exact X.Y.Z tags reachable from HEAD are a baseline: a pre-release (0.4.0-rc1) or a
# tag on an unmerged branch must not be taken for the last release.
last=""
while read -r tag; do
  if [[ $tag =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then last=$tag; fi
done < <(git tag -l --merged HEAD | sort -V)

if [ -z "$last" ]; then
  echo "next_version.sh: no X.Y.Z tag reachable from HEAD; tag the first release by hand" >&2
  exit 1
fi

if [ -z "$(git log "$last..HEAD" --oneline)" ]; then
  exit 0
fi

IFS=. read -r major minor patch <<<"$last"
echo "$major.$minor.$((patch + 1))"
