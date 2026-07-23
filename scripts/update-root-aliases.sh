#!/usr/bin/env bash
# Regenerate the WhiteNoiseLinux root alias block from the AppState global.
#
# Every non-UI-internal `in-out property` in ui/shell/app-state.slint gets a
# two-way alias on the window root so Rust keeps `ui.set_x()` / `ui.get_x()`.
# Callbacks are NOT aliased — Rust binds those on the global directly
# (`ui.global::<AppState>().on_x(..)`); root aliases to global callbacks are
# deprecated in Slint. Members preceded by a "UI-internal, not part of the
# Rust contract" annotation are skipped.
#
# Run after adding/removing a Rust-facing property in app-state.slint.
set -euo pipefail
cd "$(dirname "$0")/.."

STATE=ui/shell/app-state.slint
ROOT=ui/white-noise-linux.slint
BEGIN='    // BEGIN GENERATED ALIASES — edit ui/shell/app-state.slint and run scripts/update-root-aliases.sh'
END='    // END GENERATED ALIASES'

grep -q "BEGIN GENERATED ALIASES" "$ROOT" || { echo "marker missing in $ROOT" >&2; exit 1; }

aliases=$(awk '
  /UI-internal, not part of the Rust contract/ { skip = 1; next }
  {
    if (match($0, /^    in-out property <[^>]+> [a-zA-Z0-9-]+(: .*)?;/)) {
      if (skip) { skip = 0; next }
      tmp = $0
      sub(/^    in-out property </, "", tmp); ty = tmp; sub(/>.*/, "", ty)
      nm = tmp; sub(/^[^>]*> /, "", nm); sub(/[:;].*/, "", nm); gsub(/ /, "", nm)
      printf "    in-out property <%s> %s <=> AppState.%s;\n", ty, nm, nm
    }
    skip = 0
  }
' "$STATE")

awk -v begin="$BEGIN" -v end="$END" -v block="$aliases" '
  index($0, "BEGIN GENERATED ALIASES") { print begin; print block; inblock = 1; next }
  index($0, "END GENERATED ALIASES")   { print end; inblock = 0; next }
  !inblock { print }
' "$ROOT" > "$ROOT.tmp" && mv "$ROOT.tmp" "$ROOT"

echo "regenerated $(echo "$aliases" | wc -l) aliases in $ROOT"
