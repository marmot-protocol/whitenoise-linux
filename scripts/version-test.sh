#!/usr/bin/env bash
set -euo pipefail
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/scripts" "$fixture/app"
cp "$(dirname "$0")/version.sh" "$fixture/scripts/"
cd "$fixture"

printf 'APP_VERSION :: "2028.2.29+12"\n' > app/advanced.odin
test "$(bash scripts/version.sh)" = '2028.2.29+12'
test "$(bash scripts/version.sh v2028.2.29-build.12)" = '2028.2.29+12'
for tag in v2028.2.29-build.13 v2028.2.28-build.12 v0.1.0 ''; do
  if bash scripts/version.sh "$tag" >/dev/null 2>&1; then
    echo "Accepted mismatched tag: $tag" >&2
    exit 1
  fi
done
for version in 2026.2.29+1 2026.4.31+1 2026.09.15+1 2026.9.15+0 2026.9.15+01 2026.9.15 0.1.0 ''; do
  printf 'APP_VERSION :: "%s"\n' "$version" > app/advanced.odin
  if bash scripts/version.sh >/dev/null 2>&1; then
    echo "Accepted invalid version: $version" >&2
    exit 1
  fi
done
