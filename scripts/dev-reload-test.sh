#!/usr/bin/env bash
# Actual code replacement in an isolated copy, without relays or user data.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" != --session ]; then
	"$HERE/scripts/build.sh" stage
	cc -Wall -Wextra -Werror "$HERE/scripts/dev-session.c" -o "$HERE/build/dev-session-test"
	exec "$HERE/build/dev-session-test" bash "$0" --session
fi
TASK_DIR=$(mktemp -d "$HERE/build/reload-test.XXXXXX")
pid=""
cleanup() {
	if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
	rm -rf "$TASK_DIR"
}
trap cleanup EXIT
cp -a "$HERE/app" "$TASK_DIR/app"
for entry in vendor marmot themes lang build observability.toml; do ln -s "$HERE/$entry" "$TASK_DIR/$entry"; done
if [ -d "$HERE/build/odin-root" ]; then export ODIN_ROOT="$HERE/build/odin-root"; fi
cc -shared -Wl,-soname,libmarmot-dev.so -o "$HERE/build/libmarmot-dev.so.next" \
	-Wl,--whole-archive "$HERE/vendor/mdk/crates/marmot-c/output/lib/libmarmot_c.a" -Wl,--no-whole-archive -lm -lpthread -ldl
mv "$HERE/build/libmarmot-dev.so.next" "$HERE/build/libmarmot-dev.so"
cc -Wall -Wextra -Werror -rdynamic "$HERE/scripts/dev-host.c" -o "$TASK_DIR/host" $(pkg-config --cflags --libs sdl3) -ldl
cc -Wall -Wextra -Werror "$HERE/scripts/dev-host-test.c" -o "$TASK_DIR/host-test" $(pkg-config --cflags --libs sdl3) -ldl
"$TASK_DIR/host-test"
odin build "$TASK_DIR/app" -o:minimal -define:WN_DEV=true -out:"$TASK_DIR/seed"
export SDL_VIDEODRIVER=dummy XDG_CONFIG_HOME="$TASK_DIR/config" WN_DEV_CMD="$TASK_DIR/cmd"
for variable in ${!WN_TEST_@}; do unset "$variable"; done
cd "$TASK_DIR"
WN_SHOT=1 WN_SHOT_FRAME=5 WN_VAULT_PW=test ./seed "$TASK_DIR/data" > seed.log 2>&1
unset WN_VAULT_PW WN_SHOT WN_SHOT_FRAME

build_module() {
	odin build "$TASK_DIR/app" -o:minimal -build-mode:dynamic -define:WN_DEV=true -define:WN_RELOAD=true \
		"-extra-linker-flags:-Wl,-rpath,$HERE/build -Wl,--version-script=$HERE/scripts/dev-exports.map" -out:"$1"
}
probe() {
	printf 'package main\nimport "core:fmt"\nimport "base:runtime"\n@(init) reload_probe :: proc "contextless" () { context = runtime.default_context(); fmt.eprintln("reload-probe:%s") }\n' "$1" > app/reload_probe.odin
}
wait_log() {
	for _ in {1..150}; do
		if grep -q "$1" host.log; then return; fi
		kill -0 "$pid" 2>/dev/null || { cat host.log; return 1; }
		sleep 0.1
	done
	cat host.log
	return 1
}
probe one
build_module "$TASK_DIR/app-one.so"
printf '%s\n' "$TASK_DIR/app-one.so" > module
./host "$TASK_DIR/module" "$TASK_DIR/data" > host.log 2>&1 &
pid=$!
echo 'get page' >> cmd
wait_log 'devctl: page = Chats'

# Syntax errors and invalid libraries must leave the current process usable.
echo 'invalid odin syntax' > app/reload_probe.odin
if build_module "$TASK_DIR/bad.so" > build-error.log 2>&1; then exit 1; fi
printf 'not an ELF library\n' > broken.so
printf '%s\n' "$TASK_DIR/broken.so" > module.next
mv module.next module
wait_log 'dev: load failed:'
echo 'get selected' >> cmd
wait_log 'devctl: selected = -1'

probe two
build_module "$TASK_DIR/app-two.so"
echo 'set editing pending-edit' >> cmd
wait_log 'devctl: editing = "pending-edit"'
printf '%s\n' "$TASK_DIR/app-two.so" > module.next
mv module.next module
sleep 0.5
! grep -q 'dev: reloaded' host.log
echo 'set editing ' >> cmd
wait_log 'dev: reloaded, window='
echo 'get page' >> cmd
wait_log 'reload-probe:two'
for _ in {1..150}; do
	if [ "$(grep -c 'devctl: page = Chats' host.log)" -eq 2 ]; then break; fi
	sleep 0.1
done
test "$(grep -c 'devctl: page = Chats' host.log)" -eq 2
test "$(grep -c '^dev: window=' host.log)" -eq 1
window=$(sed -n 's/^dev: window=//p' host.log)
grep -q "^dev: reloaded, window=$window$" host.log
! grep -q '/app-one.so' "/proc/$pid/maps"
grep -q '/app-two.so' "/proc/$pid/maps"
echo 'set editing quitting-edit' >> cmd
wait_log 'devctl: editing = "quitting-edit"'
kill "$pid"
wait "$pid"
pid=""
echo 'Reload passed: new code, same process/window, unlocked, old code unloaded; failures kept the app running.'
