#!/usr/bin/env bash
# Dev live-reload: rebuild and restart the app on any .odin change.
#
# Odin has no incremental compilation and no UI markup to reload (the
# layout is Odin code), so "live reload" here is watch + rebuild +
# restart: ~3s at -o:minimal. Set WN_VAULT_PW (and the usual WN_TEST_*
# hooks, or the restore-last-chat pref) so each restart lands back where
# you were instead of at the vault gate.
#
# Usage: ./dev.sh [args passed to build/app]
# Env:   WN_DEV_OPT   optimization level (default -o:minimal;
#                     use -o:speed when profiling the STL orbit path)
# Needs: inotify-tools
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OPT="${WN_DEV_OPT:--o:minimal}"
# build.sh only creates the ODIN_ROOT overlay when the installed odin is
# missing its vendor/stb archives; without one, the plain root is fine.
OVERLAY="$HERE/build/odin-root"

command -v inotifywait >/dev/null || { echo "dev.sh needs inotify-tools"; exit 1; }
# First run stages mdk/clay/twemoji and, if needed, the ODIN_ROOT overlay.
[ -x "$HERE/build/app" ] || "$HERE/build.sh"
ODIN_ROOT_ARG=()
[ -d "$OVERLAY" ] && ODIN_ROOT_ARG=(ODIN_ROOT="$OVERLAY")

pid=""
stop() { [ -n "$pid" ] && kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; pid=""; }
trap 'stop; exit 0' INT TERM

while :; do
	# Unlink before building: overwriting the binary while the previous
	# instance still maps it leaves a half-written file that segfaults
	# in libc's init, long before main. The running process keeps its
	# own inode, so it survives the rm and a failed build leaves it up.
	rm -f "$HERE/build/app"
	if env "${ODIN_ROOT_ARG[@]}" odin build "$HERE/app" $OPT -out:"$HERE/build/app"; then
		stop
		"$HERE/build/app" "$@" &
		pid=$!
	else
		echo "==> build failed, keeping the running app"
	fi
	inotifywait -qq -e close_write,moved_to,delete --include '\.odin$' \
		-r "$HERE/app" "$HERE/marmot"
done
