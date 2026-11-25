#!/usr/bin/env bash
# Assemble package-private tests outside the production source tree.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
usage() {
  echo "Usage: tests/odin.sh app [compiler flags [-- runner args] | --isolated]" >&2
  echo "       tests/odin.sh app/sdlrl [compiler flags [-- runner args]]" >&2
  exit 1
}
package="${1:-}"
case "$package" in
app | app/sdlrl) ;;
*) usage ;;
esac
shift
isolated=()
runner_args=()
if [ "${1:-}" = --isolated ]; then
  # The names come from the app tests, so a name passed here or a run of
  # another package would silently test something else.
  if [ "$package" != app ] || [ $# -ne 1 ]; then
    usage
  fi
  # A test that needs a process of its own opens with
  # `if !test_isolated("name") {return}`, which skips it in the shared run.
  # That call is also the list of tests to run alone, so a new one touches
  # only its own file.
  mapfile -t isolated < <(
    grep -ohE 'test_isolated\("[a-z0-9_]+"\)' "$HERE"/tests/app/*.odin | cut -d'"' -f2 | sort -u
  )
  set --
else
  for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = -- ]; then
      runner_args=("${@:i+1}")
      set -- "${@:1:i-1}"
      break
    fi
  done
fi
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}"
bash "$HERE/scripts/observability.sh"

if [ -d "$HERE/build/odin-root" ]; then
  export ODIN_ROOT="$HERE/build/odin-root"
fi
LINK_ARGS=()
TEST_COMMAND=()
case "$(uname -s)" in
OpenBSD)
  LINK_ARGS=('-extra-linker-flags:-Wl,--wrap=execve,--exclude-libs=libmarmot_c.a')
  ;;
Linux)
  LINK_ARGS=('-extra-linker-flags:-Wl,--exclude-libs=libmarmot_c.a')
  if [ "${CI:-}" = true ]; then
    # A crashed Odin test can leave a mutex locked in the test runner.
    TEST_COMMAND=(timeout --verbose --kill-after=5s 2m)
  fi
  ;;
esac

run_tests() {
  "${TEST_COMMAND[@]}" "$fixture/test" "${runner_args[@]}"
  local check
  for check in "${isolated[@]}"; do
    SDL_VIDEODRIVER=dummy "${TEST_COMMAND[@]}" "$fixture/test" "-tests:$check"
  done
}

mkdir -p "$HERE/build"
if [ -n "${WN_ODIN_TEST_BUILD_KEY:-}" ]; then
  source "$HERE/scripts/build-cache.sh"
  printf -v flags '%q ' "$package" "${LINK_ARGS[@]}" "$@"
  key="$(build_cache_key "$WN_ODIN_TEST_BUILD_KEY $flags")"
  variant="$(build_cache_key "$flags")"
  fixture="$HERE/build/odin-test-cache/$variant"
  if build_cache_fresh "$key" "$fixture/stamp" "$fixture/test"; then
    echo "==> native test cache hit: $package $*"
    run_tests
    exit 0
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
for module in nevent profiles vault_gate vault_pw tick grouphero video geo; do
  sed '/^package main$/d' "$fixture/app/${module}_internal_test.odin" >>"$fixture/app/$module.odin"
  rm "$fixture/app/${module}_internal_test.odin"
done
# Mobile onboarding exercises the gate's file-private layout too. Reuse its
# production imports while retaining the test's sync/testing imports.
sed '/^package main$/d; /import "base:runtime"/d; /import "core:os"/d; /import "nendo"/d; /import rl /d' "$fixture/app/mobile_onboard_test.odin" >>"$fixture/app/vault_gate.odin"
rm "$fixture/app/mobile_onboard_test.odin"
for entry in vendor marmot themes lang build; do
  ln -s "$HERE/$entry" "$fixture/$entry"
done
for helper in wn-archive wn-pdf wn-mesh wn-fbx wn-math wn-font wn-image; do
  ln -s "$HERE/build/$helper" "$fixture/$helper"
done
odin build "$fixture/$package" -build-mode:test -out:"$fixture/test" "${LINK_ARGS[@]}" "$@"
run_tests
if [ -n "${WN_ODIN_TEST_BUILD_KEY:-}" ]; then
  build_cache_store "$key" "$fixture/stamp" "$fixture/test"
fi
