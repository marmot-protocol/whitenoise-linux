// The first-run checklist, shown on the Chats page while the account
// has no chats: the three things that have to be true before a message
// can travel, each with the one action that makes it true.
package main

import "core:fmt"

import clay "../vendor/clay/bindings/odin/clay-odin"

import marmot "../marmot"

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
				N_("Publish your key package"),
				N_("It is what lets people invite you to a group."),
				N_("Check now"),
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
			N_("It is what lets people invite you to a group."),
			N_("Publish"),
			false,
		}
	case .First_Chat:
		if len(ui.chats) > 0 {
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

// First-run screen shown on the Chats page when no chats exist.
get_started_pane :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("GetStarted"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childAlignment = {x = .Center, y = .Center},
			childGap = 14,
		},
	},
	) {
		if clay.UI(clay.ID("GetStartedCard"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(fit_w(480))},
				layoutDirection = .TopToBottom,
				padding = clay.PaddingAll(single_pane() ? 16 : 24),
				childGap = 10,
			},
			backgroundColor = ROW_BG,
			cornerRadius = rr(14),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			clay.Text(tr("Get started"), {fontId = FONT_TITLE, fontSize = 22, textColor = TEXT})
			clay.Text(
				tr("Three things and you can send your first message."),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
			)

			for step in Step {
				view := step_view(ui, step)
				if clay.UI(clay.ID("StepRow", u32(step)))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						padding = {top = 10, bottom = 10},
						childGap = 12,
						childAlignment = {y = .Center},
					},
				},
				) {
					// Filled accent tick when done, hollow ordinal until then.
					if clay.UI(clay.ID("StepMark", u32(step)))(
					{
						layout = {
							sizing = {width = clay.SizingFixed(24), height = clay.SizingFixed(24)},
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = view.done ? ACCENT : {},
						cornerRadius = rr(12),
						border = view.done ? {} : clay.BorderElementConfig{color = FIELD_BORDER, width = bw()},
					},
					) {
						if view.done {
							clay.Text(
								ICON_CHECK,
								{fontId = FONT_ICON, fontSize = 10, textColor = ON_ACCENT},
							)
						} else {
							clay.Text(
								fmt.tprintf("%d", int(step) + 1),
								{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
							)
						}
					}
					if clay.UI(clay.ID("StepCol", u32(step)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							layoutDirection = .TopToBottom,
							childGap = 3,
						},
					},
					) {
						clay.Text(
							tr(view.title),
							{
								fontId = FONT_TITLE,
								fontSize = 14,
								textColor = view.done ? TEXT_DIM : TEXT,
							},
						)
						clay.Text(
							tr(view.sub),
							{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
						)
					}
					if len(view.action) > 0 {
						micro_button(step_action_id(step), view.action)
					}
				}
				if step != .First_Chat {
					if clay.UI(clay.ID("StepRule", u32(step)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(1)},
						},
						backgroundColor = DIVIDER,
					},
					) {}
				}
			}
		}
		clay.Text(
			tr("Press Ctrl P for the command palette."),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
		)
	}
}

// Plain-string id per row: indexed clay ids don't survive the query
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
		ui.new_chat_open = true
		ui.focus = .NC_Member
		return true
	}
	return false
}
