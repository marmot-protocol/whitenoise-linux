#!/usr/bin/env bash
# Assemble package-private tests outside the production source tree.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
package="${1:-}"
case "$package" in
app | app/sdlrl) ;;
*)
  echo "Usage: tests/odin.sh app|app/sdlrl [odin test flags]" >&2
  exit 1
  ;;
esac
shift
bash "$HERE/scripts/observability.sh"
if [ -d "$HERE/build/odin-root" ]; then
  export ODIN_ROOT="$HERE/build/odin-root"
fi
LINK_ARGS=()
if [ "$(uname -s)" = OpenBSD ]; then
  LINK_ARGS=('-extra-linker-flags:-Wl,--wrap=execve,--exclude-libs=libmarmot_c.a')
elif [ "$(uname -s)" = Linux ]; then
  LINK_ARGS=('-extra-linker-flags:-Wl,--exclude-libs=libmarmot_c.a')
fi
mkdir -p "$HERE/build"
if [ -n "${WN_ODIN_TEST_BUILD_KEY:-}" ]; then
  source "$HERE/scripts/build-cache.sh"
  printf -v flags '%q ' "$package" "${LINK_ARGS[@]}" "$@"
  key="$(build_cache_key "$WN_ODIN_TEST_BUILD_KEY $flags")"
  variant="$(build_cache_key "$flags")"
  fixture="$HERE/build/odin-test-cache/$variant"
  if build_cache_fresh "$key" "$fixture/stamp" "$fixture/test"; then
    echo "==> native test cache hit: $package $*"
    exec "$fixture/test"
  fi
  rm -rf "$fixture"
  mkdir -p "$fixture"
else
  fixture="$(mktemp -d "$HERE/build/odin-test.XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
fi
cp -a "$HERE/app" "$fixture/app"
cp -a "$HERE/tests/app/." "$fixture/app/"
# Internal tests share the source file's private symbols.
for module in nevent profiles vault_gate vault_pw tick grouphero video; do
  sed '/^package main$/d' "$fixture/app/${module}_internal_test.odin" >>"$fixture/app/$module.odin"
  rm "$fixture/app/${module}_internal_test.odin"
done
for entry in vendor marmot themes lang build; do
  ln -s "$HERE/$entry" "$fixture/$entry"
done
for helper in wn-archive wn-pdf wn-mesh wn-fbx wn-math wn-font wn-image; do
  ln -s "$HERE/build/$helper" "$fixture/$helper"
done
odin test "$fixture/$package" -keep-executable -out:"$fixture/test" "${LINK_ARGS[@]}" "$@"
if [ -n "${WN_ODIN_TEST_BUILD_KEY:-}" ]; then
  build_cache_store "$key" "$fixture/stamp" "$fixture/test"
fi
