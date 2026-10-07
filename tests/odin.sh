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
bash "$HERE/scripts/observability.sh"
mkdir -p "$HERE/build"
fixture="$(mktemp -d "$HERE/build/odin-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
cp -a "$HERE/app" "$fixture/app"
cp -a "$HERE/tests/app/." "$fixture/app/"
# Internal tests share the source file's private symbols.
for module in nevent profiles vault_gate vault_pw tick; do
  sed '/^package main$/d' "$fixture/app/${module}_internal_test.odin" >> "$fixture/app/$module.odin"
  rm "$fixture/app/${module}_internal_test.odin"
done
for entry in vendor marmot themes lang build; do
  ln -s "$HERE/$entry" "$fixture/$entry"
done
for helper in wn-archive wn-pdf wn-mesh wn-fbx wn-math; do
  ln -s "$HERE/build/$helper" "$fixture/$helper"
done
if [ -d "$HERE/build/odin-root" ]; then
  export ODIN_ROOT="$HERE/build/odin-root"
fi
LINK_ARGS=()
if [ "$(uname -s)" = OpenBSD ]; then
  LINK_ARGS=('-extra-linker-flags:-Wl,--wrap=execve,--exclude-libs=libmarmot_c.a')
fi
odin test "$fixture/$package" -out:"$fixture/test" "${LINK_ARGS[@]}" "$@"
