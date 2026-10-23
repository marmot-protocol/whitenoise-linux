package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
whip_payload: Model_Kind = .Whip

@(private)
whip_pane :: proc(ui: ^Ui_State) {
	anim_moving += 1
	status := rl.WhipState()
	if clay.UI(clay.ID("WhipPage"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childAlignment = {x = .Center, y = .Center},
			childGap = 12,
		},
		clip = {horizontal = true, vertical = true},
		custom = {customData = &whip_payload},
	},
	) {
		if status == .Ready {return}
		clay.Text("Whip", {fontId = FONT_TITLE, fontSize = 20, textColor = TEXT})
		if status == .Failed {
			clay.Text(
				tr("Couldn't open Whip. Please try again."),
				{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
			)
			micro_button("WhipRetry", tr("Try again"))
		} else {
			clay.Text(
				tr("Opening Whip…"),
				{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
			)
			clay.Text(
				tr("Progress is indeterminate."),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
			)
			busy_bar("WhipBusy")
		}
	}
}
