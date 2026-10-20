// New group member menu: when to list contacts, say nothing matched, or stay closed.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:testing"

@(test)
nc_member_menu_states :: proc(t: ^testing.T) {
	// An empty field leaves the hint visible instead of reporting a failed search.
	testing.expect_value(t, nc_member_menu("", 0, false), Nc_Member_Menu.Hidden)
	testing.expect_value(t, nc_member_menu("  ", 0, false), Nc_Member_Menu.Hidden)
	// A pasted address that Create group accepts is not "no matching contacts".
	testing.expect_value(t, nc_member_menu("npub1xyz", 0, true), Nc_Member_Menu.Hidden)
	testing.expect_value(t, nc_member_menu("zed", 0, false), Nc_Member_Menu.No_Matches)
	testing.expect_value(t, nc_member_menu("", 3, false), Nc_Member_Menu.Contacts)
	testing.expect_value(t, nc_member_menu("npub1xyz", 1, true), Nc_Member_Menu.Contacts)
}
