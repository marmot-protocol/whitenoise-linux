package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:sync"
import "core:testing"

@(test)
member_menu_permissions :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui := Ui_State {
		member_menu = 1,
	}
	append(&ui.members, Member_Ui{is_self = true}, Member_Ui{name = "Alice", id_hex = "alice"})
	defer delete(ui.members)
	for role in ([]bool{false, true, false}) {
		ui.members[0].is_admin = role
		for target_admin in ([]bool{false, true}) {
			ui.members[1].is_admin = target_admin
			clay.BeginLayout()
			member_menu(&ui)
			clay.EndLayout(0)
			testing.expect_value(
				t,
				clay.GetElementData(clay.ID("MemberPromote")).found,
				role && !target_admin,
			)
			testing.expect_value(
				t,
				clay.GetElementData(clay.ID("MemberDemote")).found,
				role && target_admin,
			)
			testing.expect_value(t, clay.GetElementData(clay.ID("MemberRemove")).found, role)
			testing.expect(t, clay.GetElementData(clay.ID("MemberNick")).found)
		}
	}
	previous_release := forced_release
	forced_release = true
	defer forced_release = previous_release
	defer clay.SetPointerState({-1, -1}, false)
	ui.members[1].is_admin = false
	for action in ([]string{"MemberPromote", "MemberRemove"}) {
		ui.member_menu = 1
		ui.members[0].is_admin = true
		clay.BeginLayout()
		member_menu(&ui)
		clay.EndLayout(0)
		box := clay.GetElementData(clay.ID(action)).boundingBox
		clay.SetPointerState({box.x + 1, box.y + 1}, false)
		ui.members[0].is_admin = false
		testing.expect(t, handle_member_menu(&ui))
		testing.expect_value(t, ui.confirm.kind, Confirm_Kind.None)
		testing.expect_value(t, ui.member_menu, -1)
	}
}
