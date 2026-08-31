#!/usr/bin/env bash
# Register the marmot:// scheme: substitute the
# built binary's absolute path into the .desktop template, install it
# to the user's applications dir, and point x-scheme-handler/marmot
# at it. Run after ./build.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/app"
if [ ! -x "$APP" ]; then
	echo "build/app missing; run ./build.sh first" >&2
	exit 1
fi

APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$APPS"
sed "s|@APP@|$APP|" "$ROOT/assets/whitenoise-linux.desktop" > "$APPS/whitenoise-linux.desktop"
update-desktop-database "$APPS" 2>/dev/null || true
xdg-mime default whitenoise-linux.desktop x-scheme-handler/marmot
echo "==> marmot:// links open $APP"
