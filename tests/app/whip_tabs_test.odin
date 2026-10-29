package main

import "core:encoding/json"
import "core:testing"
import rl "sdlrl"

@(test)
whip_tab_move_identity :: proc(t: ^testing.T) {
	original := [4]rl.Whip_Tab {
		{id = 11, name = "Shell", waiting = 2},
		{id = 27, name = "Editor", active = true, waiting = 5},
		{id = 42, name = "Shell", waiting = 1},
		{id = 96, name = "Logs", waiting = 7},
	}
	tabs := original
	moves := [?]struct {
		id:    u32,
		slot:  int,
		order: [4]int,
	} {
		{11, 4, {1, 2, 3, 0}}, // First to end: slot is measured before removal.
		{11, 0, {0, 1, 2, 3}}, // Last to front.
		{96, 1, {0, 3, 1, 2}}, // Insert into the middle from the right.
		{96, 3, {0, 1, 3, 2}}, // Forward middle insertion adjusts the slot.
	}
	for move in moves {
		testing.expect(t, whip_tab_move(tabs[:], move.id, move.slot))
		for index, i in move.order {
			want := original[index]
			testing.expect_value(t, tabs[i].id, want.id)
			testing.expect_value(t, tabs[i].name, want.name)
			testing.expect_value(t, tabs[i].active, want.active)
			testing.expect_value(t, tabs[i].waiting, want.waiting)
		}
	}
}

@(test)
whip_tab_move_noop :: proc(t: ^testing.T) {
	original := [3]rl.Whip_Tab {
		{id = 8, name = "First", waiting = 3},
		{id = 19, name = "Active", active = true, waiting = 1},
		{id = 31, name = "Last", waiting = 4},
	}
	tabs := original
	// Both edges of the dragged tab's own gap describe its current position.
	for slot in ([2]int{1, 2}) {
		testing.expect(t, !whip_tab_move(tabs[:], 19, slot))
	}
	testing.expect(t, !whip_tab_move(tabs[:], 8, 0))
	testing.expect(t, !whip_tab_move(tabs[:], 31, len(tabs)))
	testing.expect(t, !whip_tab_move(tabs[:], 0, 0), "zero is not a tab identity")
	testing.expect(t, !whip_tab_move(tabs[:], 77, 1), "a closed tab cannot move a replacement")
	testing.expect(t, !whip_tab_move(nil, 19, 0), "an empty projection has nothing to move")
	for want, i in original {
		testing.expect_value(t, tabs[i].id, want.id)
		testing.expect_value(t, tabs[i].name, want.name)
		testing.expect_value(t, tabs[i].active, want.active)
		testing.expect_value(t, tabs[i].waiting, want.waiting)
	}
}

@(test)
whip_tab_order_json :: proc(t: ^testing.T) {
	saved := Whip_Saved_Tab {
		account = "account-a",
		folder  = "/work/project",
		session = {11, 22, 33, 44},
		pane    = 19,
		tab     = 27,
	}
	saved.order[27], saved.order[4_000_000_000], saved.order[11] = 0, 1, 2
	defer delete(saved.order)
	encoded, err := json.marshal(saved)
	if !testing.expect_value(t, err, nil) {return}
	defer delete(encoded)
	restored: Whip_Saved_Tab
	defer {delete(restored.account); delete(restored.folder); delete(restored.order)}
	if !testing.expect_value(t, json.unmarshal(encoded, &restored), nil) {return}
	testing.expect_value(t, restored.account, saved.account)
	testing.expect_value(t, restored.folder, saved.folder)
	testing.expect_value(t, restored.session, saved.session)
	testing.expect_value(t, restored.pane, saved.pane)
	testing.expect_value(t, restored.tab, saved.tab)
	testing.expect_value(t, len(restored.order), len(saved.order))
	for id, rank in saved.order {
		actual, found := restored.order[id]
		testing.expect(t, found, "numeric tab IDs survive JSON object keys")
		testing.expect_value(t, actual, rank)
	}
}
