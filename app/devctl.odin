package main

// Dev command channel: WN_DEV_CMD names a scratch file, and whatever is
// appended to it runs on the next poll. It exists so a script can drive a
// running app without a restart and without a debugger.
//
//   echo 'click 640 400'     >> "$WN_DEV_CMD"
//   echo 'get chats[0].title' >> "$WN_DEV_CMD"
//
// Two primitives carry almost everything, so devctl does not need a new
// command every time the app grows one:
//
//   input       every user action already goes through the mouse and
//               keyboard, so click/key/type reach a button that did not
//               exist when this file was written.
//   reflection  get/set/fields/x walk Ui_State by runtime type info, so a
//               field added tomorrow is readable today.
//
// The named commands below (select, send, chats) are shorthand for things a
// script does constantly. Everything else goes through the primitives.
//
// Commands are read every DEV_POLL_FRAMES; queued input is applied every
// frame, because a click has to hold across the press/release pair the UI
// expects. Unset WN_DEV_CMD and none of it runs.

import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

@(private = "file")
DEV_POLL_FRAMES :: 6

// A click is press, hold, release: the UI focuses on press and acts on
// release, and clay needs a frame in between to see the pointer down.
@(private = "file")
CLICK_HOLD_FRAMES :: 2

@(private = "file")
Dev_Input_Kind :: enum {
	Move,
	Click,
	Key,
	Text,
	Scroll,
}

@(private = "file")
Dev_Input :: struct {
	kind: Dev_Input_Kind,
	pos:  [2]f32,
	key:  rl.KeyboardKey,
	text: string,
	at:   int, // frame this fires on
}

@(private = "file")
dev_queue: [dynamic]Dev_Input

// Frame the next queued action may occupy. Actions are serialized so a
// click's release is not overwritten by the action behind it.
@(private = "file")
dev_next_frame: int

// The pointer devctl last moved to, held across frames so a click does not
// snap the position back between its press and its release.
@(private = "file")
dev_pointer: [2]f32
@(private = "file")
dev_pointer_on: bool

// Where the real mouse sat when devctl took the pointer, so a genuine
// mouse move can be told from the cursor simply sitting still.
@(private = "file")
dev_real_at: [2]f32

// devctl_poll drains the command file and applies any input due this frame.
// pointer is the frame's clay pointer position, which a queued move or click
// overrides in place.
devctl_poll :: proc(ui: ^Ui_State, client: ^marmot.Client, frame: int, pointer: ^clay.Vector2) {
	if os.get_env("WN_DEV_CMD", context.temp_allocator) == "" {
		return
	}
	anim_moving += 1 // frame-indexed automation keeps its normal cadence
	if frame %% DEV_POLL_FRAMES == 0 {
		devctl_read(ui, client, frame)
	}
	devctl_apply_input(frame, pointer)
}

@(private = "file")
devctl_read :: proc(ui: ^Ui_State, client: ^marmot.Client, frame: int) {
	path := os.get_env("WN_DEV_CMD", context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) == 0 {
		return
	}
	// Truncate before running: a command that takes the app down must not
	// come back and take it down again on the next poll.
	_ = os.write_entire_file(path, []byte{})

	for line in strings.split_lines(string(data), context.temp_allocator) {
		devctl_run(ui, client, frame, strings.trim_space(line))
	}
}

// ── Input ───────────────────────────────────────────────────────────

@(private = "file")
dev_enqueue :: proc(frame: int, act: Dev_Input, frames: int) {
	act := act
	act.at = max(dev_next_frame, frame + 1)
	dev_next_frame = act.at + frames
	append(&dev_queue, act)
}

@(private = "file")
devctl_apply_input :: proc(frame: int, pointer: ^clay.Vector2) {
	if dev_pointer_on {
		pointer^ = transmute(clay.Vector2)dev_pointer
		test_pointer = dev_pointer
		test_pointer_on = true
	}

	// The synthetic pointer stays where devctl left it, the way a real
	// mouse would, so a `move` still holds for the `scroll` behind it.
	// The real mouse takes it back the moment it actually moves, or one
	// scripted click would pin the pointer for the rest of the session.
	real := rl.GetMousePosition()
	if dev_pointer_on && (abs(real.x - dev_real_at.x) > 2 || abs(real.y - dev_real_at.y) > 2) {
		dev_pointer_on = false
		test_pointer_on = false
	}
	if !dev_pointer_on {
		dev_real_at = {real.x, real.y}
	}

	for i := 0; i < len(dev_queue); {
		act := dev_queue[i]
		// A click owns three frames, so it stays in the queue until its
		// release lands. Everything else fires once.
		done := true

		switch act.kind {
		case .Move:
			if frame == act.at {
				dev_pointer, dev_pointer_on = act.pos, true
				dev_real_at = {real.x, real.y}
				pointer^ = transmute(clay.Vector2)act.pos
			} else {
				done = false
			}

		case .Click:
			switch {
			case frame < act.at:
				done = false
			case frame == act.at:
				dev_pointer, dev_pointer_on = act.pos, true
				dev_real_at = {real.x, real.y}
				pointer^ = transmute(clay.Vector2)act.pos
				forced_press = true
				rl.PushMouseButton(.LEFT, true)
				done = false
			case frame < act.at + CLICK_HOLD_FRAMES:
				pointer^ = transmute(clay.Vector2)act.pos
				rl.PushMouseButton(.LEFT, true)
				done = false
			case:
				pointer^ = transmute(clay.Vector2)act.pos
				forced_release = true
				rl.PushMouseButton(.LEFT, false)
			}

		case .Key:
			if frame == act.at {
				rl.PushKey(act.key, true)
			} else {
				done = false
			}

		case .Text:
			if frame == act.at {
				for r in act.text {
					rl.PushChar(r)
				}
				delete(act.text)
			} else {
				done = false
			}

		case .Scroll:
			if frame == act.at {
				rl.PushWheel(transmute(rl.Vector2)act.pos)
			} else {
				done = false
			}
		}

		if done {
			ordered_remove(&dev_queue, i)
			continue
		}
		i += 1
	}
}

// devctl_draw takes any screenshot queued this frame. It must be called
// between draw_frame and EndDrawing: after present the backbuffer is
// undefined, and a shot taken from devctl_poll comes back fully
// transparent.
@(private = "file")
dev_shot_path: string

devctl_draw :: proc() {
	if dev_shot_path == "" {
		return
	}
	rl.TakeScreenshot(strings.clone_to_cstring(dev_shot_path, context.temp_allocator))
	delete(dev_shot_path)
	dev_shot_path = ""
}

// ── Reflection ──────────────────────────────────────────────────────

// dev_walk resolves a path like "chats[0].title" against a value, one
// segment at a time, so any field reachable from Ui_State is readable
// without devctl knowing it exists.
@(private = "file")
dev_walk :: proc(root: any, path: string) -> (val: any, ok: bool) {
	val = root
	if path == "" {
		return val, true
	}
	for seg in strings.split(path, ".", context.temp_allocator) {
		name, _, rest := strings.partition(seg, "[")
		if name != "" {
			field := reflect.struct_field_value_by_name(val, name, true)
			if field == nil {
				fmt.printfln("devctl: no field %q", name)
				return nil, false
			}
			val = field
		}
		// Trailing "[i][j]" on this segment.
		for len(rest) > 0 {
			idx_text, _, tail := strings.partition(rest, "]")
			rest = tail
			if len(rest) > 0 && rest[0] == '[' {
				rest = rest[1:]
			}
			i, parsed := strconv.parse_int(strings.trim_space(idx_text))
			if !parsed {
				fmt.printfln("devctl: bad index %q", idx_text)
				return nil, false
			}
			n := reflect.length(val)
			if i < 0 || i >= n {
				fmt.printfln("devctl: index %d out of range (len %d)", i, n)
				return nil, false
			}
			val = reflect.index(val, i)
		}
	}
	return val, true
}

@(private = "file")
dev_print :: proc(path: string, val: any) {
	if s, is_str := reflect.as_string(val); is_str {
		fmt.printfln("devctl: %s = %q  (%v)", path, s, val.id)
		return
	}
	fmt.printfln("devctl: %s = %v  (%v @ %p)", path, val, val.id, val.data)
}

// dev_set writes a scalar. Strings are cloned and the old bytes are left
// alone: devctl cannot know whether they were owned, and a dev-session leak
// is cheaper than freeing a literal.
@(private = "file")
dev_set :: proc(val: any, text: string) -> bool {
	kind := reflect.type_kind(val.id)
	#partial switch kind {
	case .Boolean:
		on := text == "true" || text == "1"
		(^bool)(val.data)^ = on
	case .Integer:
		n, ok := strconv.parse_int(text)
		if !ok {
			return false
		}
		return dev_set_int(val, n)
	case .Float:
		f, ok := strconv.parse_f64(text)
		if !ok {
			return false
		}
		switch reflect.size_of_typeid(val.id) {
		case 4:
			(^f32)(val.data)^ = f32(f)
		case 8:
			(^f64)(val.data)^ = f
		case:
			return false
		}
	case .String:
		(^string)(val.data)^ = strings.clone(text)
	case:
		fmt.printfln("devctl: cannot set a %v", kind)
		return false
	}
	return true
}

@(private = "file")
dev_set_int :: proc(val: any, n: int) -> bool {
	switch reflect.size_of_typeid(val.id) {
	case 1:
		(^u8)(val.data)^ = u8(n)
	case 2:
		(^u16)(val.data)^ = u16(n)
	case 4:
		(^i32)(val.data)^ = i32(n)
	case 8:
		(^int)(val.data)^ = n
	case:
		return false
	}
	return true
}

// dev_hex dumps raw bytes at a value's address, the one thing reflection
// cannot express: what the memory actually holds.
@(private = "file")
dev_hex :: proc(val: any, count: int) {
	bytes := ([^]u8)(val.data)
	for row := 0; row < count; row += 16 {
		line := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&line, "devctl: %p  ", rawptr(uintptr(val.data) + uintptr(row)))
		for col in 0 ..< 16 {
			if row + col < count {
				fmt.sbprintf(&line, "%02x ", bytes[row + col])
			} else {
				fmt.sbprint(&line, "   ")
			}
		}
		fmt.sbprint(&line, " |")
		for col in 0 ..< 16 {
			if row + col >= count {
				break
			}
			c := bytes[row + col]
			fmt.sbprintf(&line, "%c", c >= 32 && c < 127 ? rune(c) : '.')
		}
		fmt.sbprint(&line, "|")
		fmt.println(strings.to_string(line))
	}
}

// ── Commands ────────────────────────────────────────────────────────

@(private = "file")
devctl_run :: proc(ui: ^Ui_State, client: ^marmot.Client, frame: int, line: string) {
	if len(line) == 0 || strings.has_prefix(line, "#") {
		return
	}
	verb, _, arg := strings.partition(line, " ")
	arg = strings.trim_space(arg)

	switch verb {
	// ── input ──
	case "move":
		if pos, ok := dev_xy(arg); ok {
			dev_enqueue(frame, Dev_Input{kind = .Move, pos = pos}, 1)
		}

	case "click":
		if pos, ok := dev_xy(arg); ok {
			dev_enqueue(frame, Dev_Input{kind = .Click, pos = pos}, CLICK_HOLD_FRAMES + 2)
		}

	case "key":
		key, ok := reflect.enum_from_name(rl.KeyboardKey, arg)
		if !ok {
			fmt.printfln("devctl: unknown key %q", arg)
			return
		}
		dev_enqueue(frame, Dev_Input{kind = .Key, key = key}, 1)

	case "type":
		dev_enqueue(frame, Dev_Input{kind = .Text, text = strings.clone(arg)}, 1)

	case "scroll":
		// clay scrolls the container under the pointer, so a scroll is
		// only meaningful somewhere: "scroll DY" uses wherever the
		// pointer already is, "scroll DY X Y" moves there first.
		dy_text, _, at := strings.partition(arg, " ")
		dy, ok := strconv.parse_f64(strings.trim_space(dy_text))
		if !ok {
			fmt.printfln("devctl: bad scroll %q", arg)
			return
		}
		if pos, has_at := dev_xy(strings.trim_space(at)); has_at {
			dev_enqueue(frame, Dev_Input{kind = .Move, pos = pos}, 1)
		}
		dev_enqueue(frame, Dev_Input{kind = .Scroll, pos = {0, f32(dy)}}, 1)

	case "unpoint":
		dev_pointer_on = false
		test_pointer_on = false
		fmt.println("devctl: pointer released to the real mouse")

	// ── memory ──
	case "get":
		if val, ok := dev_walk(ui^, arg); ok {
			dev_print(arg, val)
		}

	case "set":
		path, _, value := strings.partition(arg, " ")
		val, ok := dev_walk(ui^, path)
		if !ok {
			return
		}
		if dev_set(val, strings.trim_space(value)) {
			dev_print(path, val)
		} else {
			fmt.printfln("devctl: could not set %s", path)
		}

	case "fields":
		val, ok := dev_walk(ui^, arg)
		if !ok {
			return
		}
		names := reflect.struct_field_names(val.id)
		if len(names) == 0 {
			fmt.printfln("devctl: %s is a %v, not a struct", arg, val.id)
			return
		}
		for name in names {
			field := reflect.struct_field_value_by_name(val, name, true)
			fmt.printfln("devctl: %s.%s : %v", arg, name, field.id)
		}

	case "len":
		if val, ok := dev_walk(ui^, arg); ok {
			fmt.printfln("devctl: len(%s) = %d", arg, reflect.length(val))
		}

	case "x":
		path, _, count_text := strings.partition(arg, " ")
		val, ok := dev_walk(ui^, path)
		if !ok {
			return
		}
		count := 64
		if n, parsed := strconv.parse_int(strings.trim_space(count_text)); parsed {
			count = n
		}
		dev_hex(val, count)

	// ── shorthand ──
	case "chats":
		for chat, i in ui.chats {
			fmt.printfln("devctl: [%d] %q %s", i, chat.title, chat.group_id)
		}

	case "select":
		if client == nil {
			fmt.println("devctl: no client")
			return
		}
		for chat, i in ui.chats {
			if strings.contains(chat.title, arg) {
				select_chat(ui, client, i)
				fmt.printfln("devctl: selected [%d] %q", i, chat.title)
				return
			}
		}
		fmt.printfln("devctl: no chat matching %q", arg)

	case "send":
		if client == nil {
			fmt.println("devctl: no client")
			return
		}
		if ui.selected < 0 || ui.selected >= len(ui.chats) {
			fmt.println("devctl: select a chat first")
			return
		}
		queue_send(ui, client, arg)
		fmt.printfln("devctl: sent %q to %q", arg, ui.chats[ui.selected].title)

	case "archive":
		if client == nil {
			fmt.println("devctl: no client")
			return
		}
		target, _, on_off := strings.partition(arg, " ")
		on_off = strings.trim_space(on_off)
		if on_off != "on" && on_off != "off" {
			fmt.println("devctl: archive TITLE|GROUP_ID on|off")
			return
		}
		// A group that is already archived is in neither list (the
		// archived rail only loads on its own page), so a raw group id
		// has to work as a target too.
		group_id := target
		for chat in ui.chats {
			if strings.contains(chat.title, target) {
				group_id = chat.group_id
				break
			}
		}
		set_archived(ui, client, group_id, on_off == "on")
		fmt.printfln("devctl: archived=%v %s", on_off == "on", group_id)

	case "state":
		snapshot := debug_state_json(ui)
		defer delete(snapshot)
		fmt.println(snapshot)

	case "shot":
		// Held until devctl_draw: devctl_poll runs before the frame is
		// drawn, and reading the backbuffer then yields a transparent
		// image (main.odin says why).
		dev_shot_path = strings.clone(arg == "" ? "wn-devctl-shot.png" : arg)

	case "help":
		fmt.println(DEV_HELP)

	case:
		fmt.printfln("devctl: unknown command %q (try 'help')", verb)
	}
}

@(private = "file")
dev_xy :: proc(arg: string) -> (pos: [2]f32, ok: bool) {
	// An absent position is not an error: "scroll DY" omits it on purpose.
	if arg == "" {
		return {}, false
	}
	x_text, _, y_text := strings.partition(arg, " ")
	x, x_ok := strconv.parse_f64(strings.trim_space(x_text))
	y, y_ok := strconv.parse_f64(strings.trim_space(y_text))
	if !x_ok || !y_ok {
		fmt.printfln("devctl: expected 'x y', got %q", arg)
		return {}, false
	}
	return {f32(x), f32(y)}, true
}

@(private = "file")
DEV_HELP :: `devctl commands (append one per line to $WN_DEV_CMD)
  input   move X Y | click X Y | key NAME | type TEXT
          scroll DY [X Y] | unpoint (hand the pointer back)
  memory  get PATH | set PATH VALUE | fields PATH | len PATH | x PATH [BYTES]
          PATH is relative to Ui_State: chats[0].title, prefs.locale
  chat    chats | select TITLE | send TEXT | archive TITLE|ID on|off
  other   state | shot [PATH] | help
  key names are rl.KeyboardKey values, uppercase: ENTER, ESCAPE, TAB,
  BACKSPACE, F5. 'fields ' with an empty path lists all of Ui_State.`
