#!/usr/bin/env bash
# Rebuild Odin code in-process. The host owns the window; each library
# shuts down its workers and restores the session before replacing code.
# Unlock once per just dev session. The key stays in an anonymous memory file.
#
# Usage: just dev [data-dir]
# Env: WN_DEV_OPT (default -o:minimal), WN_DEV_CMD (default build/dev-cmd).
# Append commands such as 'state', 'select New group', or 'send hello'
# to WN_DEV_CMD to drive the running app. Needs inotify-tools.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" != --dev-session ]; then
	mkdir -p "$HERE/build"
	cc -Wall -Wextra -Werror "$HERE/scripts/dev-session.c" -o "$HERE/build/dev-session.next" || exit $?
	mv "$HERE/build/dev-session.next" "$HERE/build/dev-session"
	exec "$HERE/build/dev-session" bash "$HERE/scripts/dev.sh" --dev-session "$@"
fi
shift
OPT="${WN_DEV_OPT:--o:minimal}"
export WN_DEV_CMD="${WN_DEV_CMD:-$HERE/build/dev-cmd}"
command -v inotifywait >/dev/null || { echo "just dev needs inotify-tools"; exit 1; }
"$HERE/scripts/build.sh" stage {WN_DEV_VAULT_FD}>&- || exit $?
ODIN_ROOT_ARG=()
[ -d "$HERE/build/odin-root" ] && ODIN_ROOT_ARG=(ODIN_ROOT="$HERE/build/odin-root")
DEV_DIR=$(mktemp -d "$HERE/build/dev.XXXXXX")
MARMOT="$HERE/vendor/mdk/crates/marmot-c/output/lib/libmarmot_c.a"
pid=""
last_source=""
last_host=""
last_native=""
generation=0

# Watch the root so atomic DEPS_PIN replacements remain visible.
coproc WATCH { exec inotifywait -mq -e close_write,moved_to,delete,create \
	--format '%w%f' \
	--exclude '/(\.git|\.ngit|\.flatpak-builder|build|vendor)(/|$)' -r \
	"$HERE" {WN_DEV_VAULT_FD}>&-; }
watch_pid=$WATCH_PID
watch_fd=${WATCH[0]}
stop() {
	if [ -n "$pid" ]; then
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
		pid=""
	fi
}
cleanup() {
	stop
	kill "$watch_pid" 2>/dev/null || true
	wait "$watch_pid" 2>/dev/null || true
	rm -f "$DEV_DIR"/app-*.so "$DEV_DIR"/module*
	rmdir "$DEV_DIR"
}
trap cleanup EXIT
trap 'exit 0' INT TERM

build_module() {
	# Native helpers and SDK patches use the same staging rules as release builds.
	if [ -n "$last_native" ] && [ "$native_hash" != "$last_native" ]; then
		"$HERE/scripts/build.sh" stage {WN_DEV_VAULT_FD}>&- || return $?
	fi
	last_native="$native_hash"
	if [ ! -f "$HERE/build/libmarmot-dev.so" ] || [ "$MARMOT" -nt "$HERE/build/libmarmot-dev.so" ]; then
		cc -shared -Wl,-soname,libmarmot-dev.so -o "$HERE/build/libmarmot-dev.so.next" \
			-Wl,--whole-archive "$MARMOT" -Wl,--no-whole-archive -lm -lpthread -ldl {WN_DEV_VAULT_FD}>&- || return $?
		mv "$HERE/build/libmarmot-dev.so.next" "$HERE/build/libmarmot-dev.so" || return $?
		last_host="" # A changed stable runtime needs a new host process.
	fi
	if [ "$host_hash" != "$last_host" ]; then
		cc -Wall -Wextra -Werror -rdynamic "$HERE/scripts/dev-host.c" -o "$HERE/build/dev-host.next" \
			$(pkg-config --cflags --libs sdl3) -ldl {WN_DEV_VAULT_FD}>&- || return $?
	fi
	env "${ODIN_ROOT_ARG[@]}" odin build "$HERE/app" $OPT -build-mode:dynamic \
		-define:WN_DEV=true -define:WN_RELOAD=true -out:"$module" \
		"-extra-linker-flags:-Wl,-rpath,$HERE/build -Wl,--version-script=$HERE/scripts/dev-exports.map" {WN_DEV_VAULT_FD}>&-
}

while :; do
	host_hash=$(sha256sum "$HERE/scripts/dev-host.c")
	native_hash=$({ find "$HERE/app" -maxdepth 1 -type f \( -name '*.c' -o -name '*.h' \) -print0 | sort -z | xargs -0 sha256sum; sha256sum "$HERE/DEPS_PIN" "$HERE/patches/"*.patch "$HERE/scripts/build.sh"; } | sha256sum)
	source_hash=$({ find "$HERE/app" "$HERE/marmot" "$HERE/themes" "$HERE/lang" -type f -print0 | sort -z | xargs -0 sha256sum; sha256sum "$HERE/scripts/dev-host.c" "$HERE/scripts/dev-exports.map"; printf '%s\n' "$native_hash"; } | sha256sum)
	if [ "$source_hash" = "$last_source" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		echo "==> unchanged source, keeping the running app"
	else
		generation=$((generation + 1))
		module="$DEV_DIR/app-$generation.so"
		if build_module; then
			"$HERE/scripts/vet-imports.sh" {WN_DEV_VAULT_FD}>&- || true
			if [ "$host_hash" != "$last_host" ]; then
				stop
				mv "$HERE/build/dev-host.next" "$HERE/build/dev-host" || exit $?
				last_host="$host_hash"
			fi
			printf '%s\n' "$module" > "$DEV_DIR/module.next"
			mv "$DEV_DIR/module.next" "$DEV_DIR/module" || exit $?
			last_source="$source_hash"
			if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
				: > "$WN_DEV_CMD"
				"$HERE/build/dev-host" "$DEV_DIR/module" "$@" &
				pid=$!
			fi
		else
			echo "==> build failed, keeping the running app"
		fi
	fi
	while :; do
		read -r -u "$watch_fd" changed || exit 0
		case "$changed" in
			*.odin|*.c|*.h|*.toml|*.po|*.map|*.patch|*.sh|*/DEPS_PIN) break ;;
		esac
	done
	while read -r -t 0.1 -u "$watch_fd" changed; do :; done
done
