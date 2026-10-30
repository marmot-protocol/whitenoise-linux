// First-run progression and chat readiness actions.
package main

import "core:fmt"

import "nendo"
import rl "sdlrl"

import marmot "../marmot"

@(private)
Onboard_Stage :: enum {
	Protect,
	Account,
	Chat,
}

@(private)
onboard_steps :: proc(active: Onboard_Stage) {
	labels := [Onboard_Stage]string {
		.Protect = N_("Protect this computer"),
		.Account = N_("Choose your account"),
		.Chat    = N_("Start a chat"),
	}
	numbers := [Onboard_Stage]string {
		.Protect = "1",
		.Account = "2",
		.Chat    = "3",
	}
	if nendo.box(nendo.id("OnboardSteps"))({width = nendo.grow(), direction = .Column}) {
		for stage in Onboard_Stage {
			current := stage == active
			complete := stage < active
			mark := nendo.id("OnboardStageMark", u32(stage))
			selected := anim_to(anim_key(mark.id, 1), current ? 1 : 0, HOVER_RATE)
			finished := anim_to(anim_key(mark.id, 2), complete ? 1 : 0, HOVER_RATE)
			arrived := stagger(nendo.id("OnboardSteps").id, int(stage))
			ink := mix_color(TEXT_LO, ACCENT, finished)
			ink = mix_color(ink, ON_ACCENT, selected)
			if nendo.box(nendo.id("OnboardStage", u32(stage)))(
			{width = nendo.grow(), gap = 12, align = {y = .Center}},
			) {
				if nendo.box(mark)(
				{
					width = nendo.fixed(28),
					height = nendo.fixed(28),
					align = {x = .Center, y = .Center},
				},
				) {
					// Only the badge settles; the row and its label never move.
					side := 26 + 2 * arrived
					if nendo.box(nendo.id("OnboardStageBadge", u32(stage)))(
					{
						width = nendo.fixed(side),
						height = nendo.fixed(side),
						align = {x = .Center, y = .Center},
						color = fade(
							mix_color(fade(ACCENT, 0.12 * finished), ACCENT, selected),
							0.8 + 0.2 * arrived,
						),
						radius = rr(14),
						border = {
							color = mix_color(FIELD_BORDER, ACCENT, max(selected, finished)),
							width = bw(),
						},
					},
					) {
						if complete {glow(nendo.id("OnboardStageBadge", u32(stage)), ACCENT, (1 - finished) * 0.2, 6)}
						nendo.text(
							complete ? ICON_CHECK : numbers[stage],
							{
								font = complete ? FONT_ICON : FONT_BODY,
								size = complete ? 12 : 14,
								color = ink,
							},
						)
					}
				}
				nendo.text(
					tr(labels[stage]),
					{
						font = FONT_TITLE,
						size = 16,
						color = fade(
							current ? TEXT : complete ? TEXT_DIM : TEXT_LO,
							0.8 + 0.2 * arrived,
						),
					},
				)
			}
			if stage != .Chat {
				if nendo.box(nendo.id("OnboardStageLink", u32(stage)))({padding = {left = 13}}) {
					if nendo.box(nendo.id("OnboardStageLine", u32(stage)))(
					{width = nendo.fixed(2), height = nendo.fixed(10), color = DIVIDER},
					) {
						if nendo.box(nendo.id("OnboardStageFill", u32(stage)))(
						{
							width = nendo.fixed(2),
							height = nendo.fixed(10 * finished),
							color = ACCENT,
						},
						) {}
					}
				}
			}
		}
	}
}

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
			onboard_steps(.Chat)

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
					// Readiness status, separate from the numbered setup stages.
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
							nendo.text("·", {font = FONT_BODY, size = 12, color = TEXT_DIM})
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
