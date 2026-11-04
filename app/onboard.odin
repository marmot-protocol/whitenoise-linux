// The first-run checklist, shown on the Chats page while the account
// has no chats besides Notes to self: the three things needed before a message
// can travel, each with the one action that makes it true.
package main

import "core:fmt"

import "nendo"
import rl "sdlrl"

import marmot "../marmot"

// Notes is created automatically, and search destinations are not joined chats.
@(private)
onboard_pending :: proc(ui: ^Ui_State) -> bool {
	for chat in ui.chats {
		if chat.search_only || chat.title == NOTES_TITLE {
			continue
		}
		if len(ui.prefs.notes_group) > 0 && chat.group_id == ui.prefs.notes_group {
			continue
		}
		return false
	}
	return true
}

@(private)
Onboard_Layout :: enum {
	Scroll,
	Inline,
}

Step :: enum {
	Relays,
	Key_Package,
	First_Chat,
}

Step_View :: struct {
	title:  string,
	sub:    string,
	action: string, // button label; "" once the step is done
	done:   bool,
}

step_view :: proc(ui: ^Ui_State, step: Step) -> Step_View {
	switch step {
	case .Relays:
		if net_state(ui) == .Online {
			return {
				N_("Connected to relays"),
				fmt.tprintf(
					tr("%d of %d relays are up."),
					ui.health.connected,
					ui.health.total_relays,
				),
				"",
				true,
			}
		}
		return {
			N_("Connect to relays"),
			N_("Relays carry your encrypted messages. The defaults are already configured."),
			N_("Check now"),
			false,
		}
	case .Key_Package:
		if !ui.kp_fetched {
			return {
				N_("Check your key package"),
				N_("A key package lets people invite you to encrypted chats."),
				N_("Check for a key package"),
				false,
			}
		}
		if len(ui.kp_list) > 0 {
			return {
				N_("Key package published"),
				fmt.tprintf(tr("%d published, so people can invite you."), len(ui.kp_list)),
				"",
				true,
			}
		}
		return {
			N_("Publish your key package"),
			N_("A key package lets people invite you to encrypted chats."),
			N_("Publish"),
			false,
		}
	case .First_Chat:
		if !onboard_pending(ui) {
			return {N_("Start your first chat"), N_("Done."), "", true}
		}
		return {
			N_("Start your first chat"),
			N_("Add someone by npub, or make a group of your own."),
			N_("New chat"),
			false,
		}
	}
	return {}
}

// Inline shares the rail's scroll container so Notes and Whip remain reachable.
get_started_pane :: proc(ui: ^Ui_State, mode: Onboard_Layout = .Scroll) {
	if nendo.box(nendo.id("GetStarted"))(
	{
		width = nendo.grow(),
		height = mode == .Inline ? nendo.fit() : nendo.grow(),
		direction = .Column,
		align = {
			x = .Center,
			y = mode == .Inline || single_pane() || f32(rl.GetScreenHeight()) / UI_ZOOM < 600 ? .Top : .Center,
		},
		gap = 14,
		padding = {top = 12, bottom = 12},
		clip = mode == .Scroll ? nendo.Clip{y = true, scroll = true} : nendo.Clip{},
	},
	) {
		if mode == .Scroll {
			scrollbar(nendo.id("GetStarted"))
		}
		if nendo.box(nendo.id("GetStartedCard"))(
		{
			width = nendo.grow(max = fit_w(480)),
			direction = .Column,
			padding = nendo.pad(single_pane() ? 16 : 24),
			gap = 10,
			color = ROW_BG,
			radius = rr(14),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			nendo.text(tr("Get started"), {font = FONT_TITLE, size = 22, color = TEXT})
			nendo.text(
				tr("Three things and you can send your first message."),
				{font = FONT_BODY, size = 12, color = TEXT_DIM},
			)

			for step in Step {
				view := step_view(ui, step)
				if nendo.box(nendo.id("StepRow", u32(step)))(
				{
					width = nendo.grow(),
					padding = {top = 10, bottom = 10},
					gap = 12,
					direction = single_pane() ? .Column : .Row,
					align = {y = .Center},
				},
				) {
					// Filled accent tick when done, hollow ordinal until then.
					if nendo.box(nendo.id("StepMark", u32(step)))(
					{
						width = nendo.fixed(24),
						height = nendo.fixed(24),
						align = {x = .Center, y = .Center},
						color = view.done ? ACCENT : {},
						radius = rr(12),
						border = view.done ? {} : nendo.Border{color = FIELD_BORDER, width = bw()},
					},
					) {
						if view.done {
							nendo.text(
								ICON_CHECK,
								{font = FONT_ICON, size = 10, color = ON_ACCENT},
							)
						} else {
							nendo.text(
								fmt.tprintf("%d", int(step) + 1),
								{font = FONT_BODY, size = 12, color = TEXT_DIM},
							)
						}
					}
					if nendo.box(nendo.id("StepCol", u32(step)))(
					{width = nendo.grow(), direction = .Column, gap = 3},
					) {
						nendo.text(
							tr(view.title),
							{font = FONT_TITLE, size = 14, color = view.done ? TEXT_DIM : TEXT},
						)
						nendo.text(tr(view.sub), {font = FONT_BODY, size = 11, color = TEXT_LO})
					}
					if len(view.action) > 0 {
						micro_button(step_action_id(step), tr(view.action))
					}
				}
				if step != .First_Chat {
					if nendo.box(nendo.id("StepRule", u32(step)))(
					{width = nendo.grow(), height = nendo.fixed(1), color = DIVIDER},
					) {}
				}
			}
		}
		if mode == .Scroll && !tap_size() {
			nendo.text(
				tr("Press Ctrl P for the command palette."),
				{font = FONT_BODY, size = 11, color = TEXT_LO},
			)
		}
	}
}

// Plain-string id per row: indexed nendo ids don't survive the query
// round trip (PORT.md Quirks).
step_action_id :: proc(step: Step) -> string {
	switch step {
	case .Relays:
		return "StepRelays"
	case .Key_Package:
		return "StepKp"
	case .First_Chat:
		return "StepChat"
	}
	return ""
}

// Checklist clicks. Runs only while the pane is on screen.
handle_onboard :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	if clicked("StepRelays") {
		health_refresh(ui, client)
		return true
	}
	if clicked("StepKp") {
		if !ui.kp_fetched {
			fetch_key_packages(ui, client)
		} else {
			publish_key_package(ui, client, .Fresh)
		}
		return true
	}
	if clicked("StepChat") {
		open_new_chat(ui, client)
		return true
	}
	return false
}
