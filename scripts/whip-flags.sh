#!/usr/bin/env bash
# Sourced by native Odin entry points; never build or fetch the optional sibling.
WHIP_ARGS=()
wn_whip_flags() {
  local root whip bridge
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return $?
  whip="$root/../whip"
  bridge="$root/app/sdlrl/whip_native.odin"
  if ! { [ "$(uname -s)" = Linux ] && [ -z "${WN_TARGET:-}" ] &&
    [ -x "$whip/build/whip" ] &&
    [ -f "$whip/build/ghostty/lib/libghostty-vt.a" ] &&
    [ -f "$whip/src/gui/sdl_embed.odin" ]; }; then
    if [ -e "$bridge" ]; then
      rm "$bridge" || return $?
    fi
    return 0
  fi
  whip="$(cd "$whip" && pwd)" || return $?

  # Whip's build-id command checks the Ghostty stamp before dispatch and
  # rebuilds when stale. Refuse that path: this integration is read-only.
  # Hooks export index paths for WN; never use those in the sibling repo.
  local -a whip_git=(env -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE git -C "$whip/vendor/ghostty")
  local revision diff stamp build_id
  revision="$("${whip_git[@]}" rev-parse HEAD)" || return $?
  diff="$(
    set -o pipefail
    {
      "${whip_git[@]}" diff --binary HEAD || exit $?
      "${whip_git[@]}" ls-files --others --exclude-standard -z -- '*.zig' '*.h' '*.c' |
        (cd "$whip/vendor/ghostty" && xargs -0 -r sha256sum)
    } | sha256sum
  )" || return $?
  stamp="$(cat "$whip/build/ghostty/.rev" 2>/dev/null)" || stamp=""
  if [ "$stamp" != "${revision}-${diff:0:12}" ]; then
    printf '%s\n' 'Whip Ghostty build is stale; build ../whip explicitly before enabling native embedding.' >&2
    return 1
  fi
  build_id="ghostty-${revision:0:12}-${diff:0:12}"
  if ! cmp -s "$root/whip-embed/bridge.odin" "$bridge"; then
    cp "$root/whip-embed/bridge.odin" "$bridge" || return $?
  fi
  WHIP_ARGS=(
    -define:WN_WHIP=true
    "-collection:whip=$whip/src"
    "-define:WHIP_BUILD_ID=$build_id"
    "-define:WN_WHIP_EXE=$whip/build/whip"
  )
}
wn_whip_flags
