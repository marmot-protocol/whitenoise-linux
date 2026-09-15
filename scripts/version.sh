#!/usr/bin/env bash
# Shared by packaging and release checks; the app embeds this same literal.
# Pass a release tag to also check that it matches the source version.
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(sed -n 's/^APP_VERSION :: "\([^"]*\)".*/\1/p' app/advanced.odin)"
if [[ ! "$version" =~ ^([0-9]{4})\.([1-9]|1[0-2])\.([1-9]|[12][0-9]|3[01])\+([1-9][0-9]*)$ ]]; then
  echo "Invalid app version: expected YYYY.M.D+REVISION, got '$version'" >&2
  exit 1
fi
date -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}" +%F >/dev/null
if [ "$#" -gt 0 ] && [ "$1" != "v${version/+/-build.}" ]; then
  echo "Release tag must be v${version/+/-build.}, got '$1'" >&2
  exit 1
fi
printf '%s\n' "$version"
