package main

import "core:sync"
import "core:testing"

@(test)
decor_motion_policy :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	old_prefs, old_backdrop, old_moving := g_prefs, BACKDROP, anim_moving
	defer {g_prefs, BACKDROP, anim_moving = old_prefs, old_backdrop, old_moving}
	ui: Ui_State
	g_prefs = &ui.prefs

	Scene :: struct {
		name:     string,
		payload:  rawptr,
		animated: bool,
	}
	for scene in ([9]Scene{{"synth", &synth_decor, true}, {"dust", &dust_decor, true}, {"scan", &scan_decor, true}, {"waves", &waves_decor, true}, {"deco", &deco_decor, false}, {"blinds", &blinds_decor, false}, {"stripes", &stripes_decor, false}, {"airmail", &airmail_decor, false}, {"", nil, false}}) {
		BACKDROP = scene.name
		// Toggle back to normal to catch a scene staying disabled after the preference changes.
		for reduced in ([3]bool{false, true, false}) {
			ui.prefs.reduce_motion = reduced
			// Existing activity belongs to other animations; decor must not clear it.
			anim_moving = 7
			expected := scene.payload
			if scene.animated && reduced {
				expected = nil
			}
			payload := decor_payload()
			testing.expectf(
				t,
				payload == expected,
				"%s: reduced=%v returned the wrong scene",
				scene.name,
				reduced,
			)
			moving := 7
			if scene.animated && !reduced {
				moving += 1
			}
			testing.expectf(
				t,
				anim_moving == moving,
				"%s: reduced=%v changed animation activity incorrectly",
				scene.name,
				reduced,
			)
		}
	}
}
