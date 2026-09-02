---
name: wn-debug-shell
description: Drive and inspect a running White Noise Linux app. devctl (WN_DEV_CMD) clicks, types, scrolls, screenshots, reads and writes any Ui_State field, and selects or sends chats without a restart or a debugger; lldb covers crashes, hangs and deadlocks. Use when asked to drive or script the app, reproduce a UI state, check or change a value at runtime, take a screenshot of the running app, or when it segfaults, panics, freezes, or renders the wrong thing. Triggers - devctl, drive the app, script the UI, click, type, scroll, screenshot, inspect state, dump memory, lldb, debugger, breakpoint, backtrace, segfault, SIGSEGV, hang, deadlock, "why did it crash", "what is X at runtime".
---

# Driving and debugging White Noise Linux

## Driving the app: use devctl, not lldb

**To make the app *do* something, do not use the debugger.** Stopping,
patching and resuming costs a round trip per action, and Odin procs take a
hidden `context` parameter so lldb cannot call them at all.

`app/devctl.odin` polls the file named by `WN_DEV_CMD` and runs what it
finds. `dev.sh` exports it as `build/dev-cmd` already; outside `dev.sh`, set
it yourself. Output goes to the app's stdout, so redirect that to a log and
tail it.

Two primitives carry almost everything, which is why devctl does not need a
new command every time the app grows one:

```sh
# input: every user action goes through the mouse and keyboard, so these
# reach a button that did not exist when devctl was written.
echo 'move X Y'          >> "$WN_DEV_CMD"
echo 'click X Y'         >> "$WN_DEV_CMD"
echo 'key BACKSPACE'     >> "$WN_DEV_CMD"   # rl.KeyboardKey names
echo 'type hello'        >> "$WN_DEV_CMD"
echo 'scroll 25 1100 700' >> "$WN_DEV_CMD"  # DY, then where
echo 'unpoint'           >> "$WN_DEV_CMD"   # hand the pointer back

# memory: reflection over Ui_State, so a field added tomorrow reads today.
echo 'get chats[0].title' >> "$WN_DEV_CMD"
echo 'set theme 3'        >> "$WN_DEV_CMD"
echo 'fields '            >> "$WN_DEV_CMD"  # empty path = Ui_State itself
echo 'len chats'          >> "$WN_DEV_CMD"
echo 'x chats[0].title 32' >> "$WN_DEV_CMD" # hex + ASCII, like a debugger

# shorthand for what a script does constantly
echo 'chats'                    >> "$WN_DEV_CMD"
echo 'select New group'         >> "$WN_DEV_CMD"
echo 'send hello'               >> "$WN_DEV_CMD"
echo 'archive New group off'    >> "$WN_DEV_CMD"
echo 'state'                    >> "$WN_DEV_CMD"
echo 'shot /tmp/x.png'          >> "$WN_DEV_CMD"
echo 'help'                     >> "$WN_DEV_CMD"
```

`fields` with an empty path lists all of `Ui_State`: that is how to find the
field for a feature you have not read the code for yet.

### What will bite you

**Clicking is destructive.** Coordinates are raw window pixels, and the
screenshot is in *physical* pixels while clay works in logical ones (they
differ by the display's scale factor, 1.25 here). A click computed off a
screenshot can land a row or two away, and rail rows sit next to archive and
delete controls. Screenshot, click, screenshot, and check `state` before
trusting a coordinate. Prefer `select`/`send` over clicking the same thing.

**The rail reorders between runs.** Never hardcode a chat index; match on
title with `chats` or `select`.

**`set` is a raw memory write, exactly like a debugger's.** It does not run
the code that reacts to the field. `set theme N` changes the number without
calling `apply_theme`, so the app keeps the old palette; the real path is
`theme_switch` (reveal.odin). Use `set` to observe, not to drive a feature
that has a proper entry point.

**Scroll needs a position.** clay scrolls the container under the pointer, so
`scroll DY` only works if the pointer is already somewhere useful; `scroll DY
X Y` moves first. Scrolling down at the bottom is correctly a no-op, which
looks like a broken command.

**Only one instance may run.** A leftover holds the data-dir lock and the
next launch exits with "White Noise is already running". `pkill -x appdbg`
(never `pkill -f`, which matches the shell running it), then wait for
`pgrep -x appdbg` to come back empty.

**`shot` is taken in the draw phase** (`devctl_draw`, called before
`EndDrawing`). Taken anywhere else the backbuffer is undefined and the PNG
comes back fully transparent, which an image viewer shows as white.

`WN_TEST_*` still covers boot-time state. devctl covers everything after it.
lldb is for the questions below: crashes, hangs, and values you cannot reach
any other way.

The release binary (`-o:speed`, no `-debug`) has no usable line info. Build a
separate debug binary. It takes ~5s and does not disturb `build/app`, so
`dev.sh` can keep running.

```sh
odin build app -debug -o:none -out:build/appdbg
```

`build.sh` only needs its `ODIN_ROOT` overlay when the installed Odin lacks
`vendor/stb/lib/stb_truetype.a`. If `build/odin-root` exists, prefix with
`env ODIN_ROOT=build/odin-root`.

## Running it

Always batch mode (`-b`), never interactive: the app is a GUI frame loop and
an interactive prompt will just sit there until the turn times out.

```sh
SDL_VIDEODRIVER=dummy WN_VAULT_PW=unlockMe WN_SHOT=1 WN_SHOT_FRAME=40 \
timeout 180 lldb -b \
  -o "b main::some_proc" \
  -o "run" \
  -o "bt 10" -o "frame variable arg_one arg_two" \
  -o "continue" \
  -- build/appdbg /tmp/wn-dbg 2>&1 | tail -40
```

- `--` separates lldb's own flags from the program and its arguments.
- `SDL_VIDEODRIVER=dummy` runs headless. Drop it to watch a real window.
- `WN_VAULT_PW=unlockMe` skips the vault gate (test account).
- `WN_SHOT=1 WN_SHOT_FRAME=N` exits after N frames, so the run ends on its
  own. Without it the app runs forever and `timeout` is the only exit.
- Pass a scratch data dir instead of `~/.local/share/whitenoise` when the run
  would write state worth keeping.
- `WN_TEST_*` (see `app/main.odin`) drives the app to the pane or action the
  breakpoint cares about. Reaching a chat pane by hand is not an option
  headless.
- End with `continue`, or the process is left stopped when lldb exits.

## Symbol names

Odin emits C++-style namespaced names. **Bare proc names do not resolve** -
`b apply_theme` silently becomes a pending breakpoint that never fires.

| Want | Write |
| --- | --- |
| An app proc | `b main::apply_theme` (package `main` is every `app/*.odin`) |
| The binding layer | `b marmot::...` |
| Odin runtime | `b runtime::panic`, `b runtime::bounds_check_error.handle_error-0` |
| A source line | `b state.odin:12` (bare filename, no path) |
| Find one | `lldb -b -o "image lookup -r -n apply_theme" build/appdbg` |

Odin procs are **not callable** from `expr`: `main::foo(...)` fails with
"'main' is not a class, namespace, or enumeration" (it collides with C
`main`), and Odin's implicit `context` argument cannot be synthesized anyway.
The `marmot_*` C entry points are plain C ABI and technically callable, but
they block on the Rust runtime and lldb SIGSTOPs them at its expression
timeout. Patch state and let the app's own code run it, or use devctl.

DWARF line info is accurate: `state.odin:12` really is line 12, and lldb
prints the surrounding source at each stop.

## Stopping where you mean to

Set every breakpoint **before** `run`. Regaining the prompt by sending SIGINT
to lldb mid-run leaves thread 1 with an unwindable stack (frame 0 in libc,
frame 1 garbage), and nothing useful can be read from it.

Breakpoint conditions cannot reference `frame`: the Rust objects linked in
export `addr2line::frame`, so lldb rejects `-c 'frame == 10'` as ambiguous.
Use an ignore count instead, which counts hits of a once-per-frame line:

```
br set -f main.odin -l 1717 -i 8     # stops with frame == 9
```

`p frame` works fine once stopped. After a `continue`, lldb sometimes prints
a stale frame 0 (in libc) while `stop reason` correctly names the breakpoint;
re-read the state from a breakpoint on a known line in `main::main` rather
than trusting that display.

## Inspecting Odin values

lldb handles Odin's slice, string and dynamic-array structs well. Index
through `.data`, which is a real pointer:

```
p theme_packs               ([dynamic]main::Theme_Pack) { data = 0x..., len = 16, cap = 16, ... }
p theme_packs.data[0].name  (string) (data = "Dark", len = 4)
p *arr.data@arr.len         all len elements at once
```

Strings print their bytes inline, so `p x.name` is normally enough.

Use `frame variable <names>` rather than bare `frame variable`: the latter
dumps Odin's implicit `context` parameter, which is a screenful of allocator
and logger fields before anything useful.

`Ui_State` is a local in `main::main`, not a global. Reach it from a pane
proc's arguments, or `frame select 1` then `p ui`.

Chat rows are `ui.chats` (`Chat_Row_Ui`), and the display field is `title`,
not `name`. **The rail reorders between runs**, so never hardcode an index:
match on `title` and read the index back.

## Crashes

lldb stops on SIGSEGV/SIGABRT by default, so reproducing under the debugger
needs no breakpoints at all:

```sh
... timeout 180 lldb -b -o "run" \
  -o "bt 20" -o "frame variable" -o "thread backtrace all -c 6" \
  -- build/appdbg /tmp/wn-dbg 2>&1 | tail -60
```

An Odin runtime panic aborts through `runtime::panic`. Break there to catch
the frame before the abort unwinds anything.

`b runtime::bounds_check_error` is the wrong breakpoint: that proc runs on
*every* bounds check, passing far more often than it fails. Break on
`runtime::bounds_check_error.handle_error-0`, the failure path only.

Nothing under `app/` calls C except `marmot/marmot.odin`, so a crash inside
marmot-c or Rust frames means the binding handed it something bad. Read the
frame where Odin becomes C, not just frame 0.

For a process that already crashed on its own, the **diagnose-crash** skill
covers the coredumpctl workflow.

## Hangs and deadlocks

`kernel.yama.ptrace_scope = 1` on this machine, so lldb **cannot attach to a
running process** it did not launch (`process attach --pid` fails outright).
Do not suggest `sudo sysctl`. Force a core dump and read that instead:

Kill leftovers with `pkill -x lldb; pkill -x appdbg`. Not `pkill -f`: the
pattern matches the shell running it, so it kills its own command. A leftover
instance also holds the data-dir lock, and the next launch exits with
"White Noise is already running".

```sh
kill -ABRT $(pgrep -x appdbg)
coredumpctl dump appdbg -o /tmp/wn.core
lldb -b -c /tmp/wn.core build/appdbg -o "thread list" -o "thread backtrace all -c 8" 2>&1 | head -80
```

Thread 1 is the UI thread. Sitting in `SDL_SYS_DelayNS` is the frame limiter
and means healthy and idle. Sitting in a `marmot::` call, a futex, or a socket
read is the bug: `app/workers.odin` exists precisely so the UI thread never
blocks on Marmot. The many threads parked in `syscall` are the SDL and worker
pool, and are normal.

## Watchpoints

For state that goes wrong with no obvious writer:

```
-o "b main::some_frame_proc" -o "run" -o "watch set variable ui.selected_group" \
-o "continue" -o "bt 10"
```

Watchpoints are hardware-limited (4 at a time) and address-based, so set them
only after the struct exists, which is why the breakpoint comes first.
