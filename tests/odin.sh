#!/usr/bin/env bash
# Assemble package-private tests outside the production source tree.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
package="${1:-}"
case "$package" in
  app|app/sdlrl) ;;
  *) echo "Usage: tests/odin.sh app|app/sdlrl [odin test flags]" >&2; exit 1 ;;
esac
shift
mkdir -p "$HERE/build"
fixture="$(mktemp -d "$HERE/build/odin-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
cp -a "$HERE/app" "$fixture/app"
cp -a "$HERE/tests/app/." "$fixture/app/"
# These tests need nevent's file-private symbols as well as package-private ones.
sed '/^package main$/d' "$fixture/app/nevent_internal_test.odin" >> "$fixture/app/nevent.odin"
rm "$fixture/app/nevent_internal_test.odin"
for entry in vendor marmot themes lang build observability.toml; do
  ln -s "$HERE/$entry" "$fixture/$entry"
done
if [ -d "$HERE/build/odin-root" ]; then
  export ODIN_ROOT="$HERE/build/odin-root"
fi
odin test "$fixture/$package" -out:"$fixture/test" "$@"
