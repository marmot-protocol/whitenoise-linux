package main

import "core:sync"
import "core:testing"
import "nendo"

@(test)
member_menu_permissions :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {nendo.set_context(previous); delete(memory)}
	ui := Ui_State {
		member_menu = 1,
	}
	append(&ui.members, Member_Ui{is_self = true}, Member_Ui{name = "Alice", id_hex = "alice"})
	defer delete(ui.members)
	for role in ([]bool{false, true, false}) {
		ui.members[0].is_admin = role
		for target_admin in ([]bool{false, true}) {
			ui.members[1].is_admin = target_admin
			nendo.begin()
			member_menu(&ui)
			nendo.end(0)
			testing.expect_value(
				t,
				nendo.element(nendo.id("MemberPromote")).found,
				role && !target_admin,
			)
			testing.expect_value(
				t,
				nendo.element(nendo.id("MemberDemote")).found,
				role && target_admin,
			)
			testing.expect_value(t, nendo.element(nendo.id("MemberRemove")).found, role)
			testing.expect(t, nendo.element(nendo.id("MemberNick")).found)
		}
	}
	previous_release := forced_release
	forced_release = true
	defer forced_release = previous_release
	defer nendo.set_pointer({-1, -1}, .Up)
	ui.members[1].is_admin = false
	for action in ([]string{"MemberPromote", "MemberRemove"}) {
		ui.member_menu = 1
		ui.members[0].is_admin = true
		nendo.begin()
		member_menu(&ui)
		nendo.end(0)
		box := nendo.element(nendo.id(action)).rect
		nendo.set_pointer({box.x + 1, box.y + 1}, .Up)
		// A menu row acts only when the press also landed on it.
		menu_press = {}
		forced_press = true
		nendo.begin()
		member_menu(&ui)
		nendo.end(0)
		forced_press = false
		ui.members[0].is_admin = false
		testing.expect(t, handle_member_menu(&ui))
		testing.expect_value(t, ui.confirm.kind, Confirm_Kind.None)
		testing.expect_value(t, ui.member_menu, -1)
	}
}
