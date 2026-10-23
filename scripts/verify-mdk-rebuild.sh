#!/usr/bin/env bash
# Execute the real MDK ABI before, during, and after a source-content edit.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-}"
if [ "$#" != 1 ]; then TARGET=; fi
case "$TARGET" in
native | linux-amd64 | linux-arm64 | windows-amd64) ;;
openbsd-amd64)
  if [ "$(uname -s)" != OpenBSD ]; then
    echo 'Run openbsd-amd64 inside the OpenBSD guest.' >&2
    exit 2
  fi
  ;;
*)
  echo "Usage: $0 {native|linux-amd64|linux-arm64|windows-amd64|openbsd-amd64}" >&2
  exit 2
  ;;
esac
unset WN_TARGET
export CARGO_TERM_COLOR=never
mkdir -p "$HERE/build/mdk-rebuild/$TARGET"
EVIDENCE="$(mktemp -d "$HERE/build/mdk-rebuild/$TARGET/run.XXXXXXXX")"
MDK="$HERE/vendor/mdk/crates/marmot-c"
SOURCE="$MDK/src/lib.rs"
original='deployment argument was NULL'
changed="$original [wn-rebuild-$TARGET-${EVIDENCE##*/}]"
dirty=0
report() {
  printf '%s\n' "$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; fi
}
cleanup() {
  local result=$?
  trap - EXIT
  if [ "$dirty" = 1 ]; then
    if cp "$EVIDENCE/lib.rs.original" "$SOURCE"; then
      report "Restored MDK source after failure; cached artifacts may still contain the sentinel."
    else
      report "ERROR: restore $SOURCE from $EVIDENCE/lib.rs.original manually."
      exit 1
    fi
  fi
  rm -f "$EVIDENCE/lib.rs.original"
  if [ "$result" != 0 ]; then report "FAIL: $TARGET (exit $result); diagnostics: $EVIDENCE"; fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Source toolchain setup only in a subshell: its exported target CC and flags
# must not change the next build's compiler-environment cache fingerprint.
probe() (
  local phase="$1" expected="$2" binary="$EVIDENCE/$1-probe" archive cc mode
  local -a flags=(-O2) libs=(-pthread -lm) run=()
  case "$TARGET" in
  native | openbsd-amd64)
    cc="${CC:-clang}"
    if [ "$(uname -s)" = Linux ]; then libs+=(-ldl); fi
    archive="$MDK/output/lib/libmarmot_c.a"
    ;;
  *)
    OUT="$HERE/build/cross/$TARGET"
    stamp_fresh() { [ -e "$1" ] && [ "$(cat "$2" 2>/dev/null || true)" = "$3" ]; }
    source "$HERE/scripts/cross-toolchain.sh"
    cc="$CC"
    flags=("${CFLAGS[@]}")
    archive="$OUT/libmarmot_c.a"
    if [ "$SYSTEM" = Windows ]; then
      binary+=.exe
      libs=(-lws2_32 -luserenv -lbcrypt -lntdll -ladvapi32 -lcrypt32 -liphlpapi -lsecur32 -lshell32 -lole32 -luuid -luser32 -lgdi32)
      export WINEPREFIX="$EVIDENCE/wine" WINEPATH="$LLVM_MINGW/x86_64-w64-mingw32/bin${WINEPATH:+;$WINEPATH}"
      run=(xvfb-run -a wine)
    else
      libs+=(-ldl)
      run=("$SYSROOT/lib/$TRIPLE/ld-linux-x86-64.so.2")
      if [ "$TARGET" = linux-arm64 ]; then
        run=(qemu-aarch64 -L "$SYSROOT" "$SYSROOT/lib/$TRIPLE/ld-linux-aarch64.so.1")
      fi
      run+=(--library-path "$SYSROOT/lib/$TRIPLE:$SYSROOT/usr/lib/$TRIPLE")
    fi
    ;;
  esac
  # Explicit archive paths prevent accidentally probing a system installation.
  for mode in static shared; do
    if [ "$mode" = shared ]; then
      case "$TARGET" in native | openbsd-amd64) archive="$MDK/output/lib/libmarmot_c.so" ;; *) break ;; esac
      flags+=("-Wl,-rpath,$MDK/output/lib")
    fi
    rm -f "$binary"
    "$cc" "${flags[@]}" -I"$MDK/include" "$HERE/scripts/mdk-rebuild-probe.c" \
      "$archive" "${libs[@]}" -o "$binary" 2>&1 | tee "$EVIDENCE/$phase-$mode-link.log"
    report "$TARGET / $phase / $mode ABI execution:"
    "${run[@]}" "$binary" "$expected" 2>&1 | tee "$EVIDENCE/$phase-$mode-probe.log"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat "$EVIDENCE/$phase-$mode-probe.log" >>"$GITHUB_STEP_SUMMARY"; fi
  done
)
phase() {
  local name="$1" expected="$2" start=$SECONDS crates
  local -a build=(bash "$HERE/scripts/build.sh")
  case "$TARGET" in native | openbsd-amd64) ;; *) build=(bash "$HERE/scripts/cross-build.sh" "$TARGET") ;; esac
  report "$TARGET / $name: starting real build (logs: $EVIDENCE/$name-build.log)"
  "${build[@]}" 2>&1 | tee "$EVIDENCE/$name-build.log"
  report "$TARGET / $name build: $((SECONDS - start)) seconds"
  crates="$(awk '/^[[:space:]]*Compiling [^ ]+ v/ {print $2}' "$EVIDENCE/$name-build.log")"
  report "$TARGET / $name Cargo recompilations: ${crates:-none}"
  case "$name" in
  unchanged) [ -z "$crates" ] || {
    report 'ERROR: unchanged build recompiled crates.'
    return 1
  } ;;
  edited | restored) [ "$crates" = marmot-c ] || {
    report 'ERROR: expected only marmot-c to recompile.'
    return 1
  } ;;
  esac
  probe "$name" "$expected"
  report "$TARGET / $name build + compiled ABI probes: $((SECONDS - start)) seconds"
}

report "### MDK cached source rebuild: $TARGET"
phase populated "$original"
cp "$SOURCE" "$EVIDENCE/lib.rs.original"
phase unchanged "$original"
source_text="$(cat "$SOURCE")"
needle="set_last_error(\"$original\");"
if [[ "$source_text" != *"$needle"* || "${source_text#*"$needle"}" == *"$needle"* ]]; then
  report 'ERROR: expected exactly one existing deployment error literal in MDK lib.rs.'
  exit 1
fi
dirty=1
printf '%s\n' "${source_text/"$needle"/"set_last_error(\"$changed\");"}" >"$SOURCE"
diff_result=0
diff -u "$EVIDENCE/lib.rs.original" "$SOURCE" >"$EVIDENCE/source-edit.patch" || diff_result=$?
if [ "$diff_result" != 1 ]; then
  report 'ERROR: source edit did not produce a readable diff.'
  exit 1
fi
cat "$EVIDENCE/source-edit.patch"
phase edited "$changed"
cp "$EVIDENCE/lib.rs.original" "$SOURCE"
dirty=0
phase restored "$original"
report "PASS: $TARGET cached, unchanged, source-edited, and source-restored ABI behavior; evidence: $EVIDENCE"
