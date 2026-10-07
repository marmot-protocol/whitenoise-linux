package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private = "file")
AGENT_CONTROLS := []string {
	"AgentHermes",
	"AgentOpenClaw",
	"AgentOpenCode",
	"AgentCodex",
	"AgentClaude",
	"AgentCopyKey",
	"AgentDocs",
}

@(private = "file")
AGENT_REVIEW_CONTROLS := []string {
	"AgentBack",
	"AgentCopyPrompt",
	"AgentCopyKey",
	"AgentGuide0",
	"AgentGuide1",
}

@(private = "file")
AGENT_LOGOS := [5]struct {
	url: string,
	png: []u8,
} {
	{"agent-logo://hermes", #load("assets/agents/hermes.png")},
	{"agent-logo://openclaw", #load("assets/agents/openclaw.png")},
	{"agent-logo://opencode", #load("assets/agents/opencode.png")},
	{"agent-logo://codex", #load("assets/agents/codex.png")},
	{"agent-logo://claude", #load("assets/agents/claude.png")},
}

// Borrow the active account's key, not the last profile loaded by another pane.
@(private)
agent_public_key :: proc(ui: ^Ui_State) -> string {
	if ui.account_ref == "" {return ""}
	for id, i in ui.account_ids {
		if id == ui.account_ref && i < len(ui.account_npubs) {
			key := ui.account_npubs[i]
			if agent_key_valid(key) {return key}
			return ""
		}
	}
	return ""
}

@(private = "file")
agent_logo :: proc(index: int, size: f32) {
	art := AGENT_LOGOS[index]
	tex := local_pic(art.url)
	if tex == nil {
		image := rl.LoadImageFromMemory(".png", raw_data(art.png), i32(len(art.png)))
		if image.data != nil {
			register_local_pic(art.url, image)
			rl.UnloadImage(image)
			tex = local_pic(art.url)
		}
	}
	tex = shaped_avatar(tex, "square")
	if clay.UI(clay.ID_LOCAL("BrandTile"))(
	{
		layout = {sizing = {clay.SizingFixed(size), clay.SizingFixed(size)}},
		image = {imageData = tex},
	},
	) {}
}

@(private)
settings_agents :: proc(ui: ^Ui_State) {
	npub := agent_public_key(ui)
	if npub == "" {
		ui.agent_connector = 0
		clay.Text(
			tr("Your public key is unavailable. Choose another account and try again."),
			{fontId = FONT_BODY, fontSize = 13, textColor = DANGER},
		)
	}
	if ui.agent_connector > 0 && ui.agent_connector <= len(AGENT_CONNECTORS) {
		agent_setup_view(ui, npub)
		return
	}

	clay.Text(
		tr("Connect an agent you run and trust."),
		{fontId = FONT_TITLE, fontSize = 24, textColor = TEXT},
	)
	clay.Text(
		tr(
			"Chat with AI agents, end-to-end encrypted like any other chat. Each agent runs on a computer or server you control, using its own account.",
		),
		{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
	)
	if clay.UI(clay.ID("AgentConnectors"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childGap = 10,
		},
	},
	) {
		for connector, i in AGENT_CONNECTORS {
			id := AGENT_CONTROLS[i]
			if clay.UI(clay.ID(id))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					padding = clay.PaddingAll(16),
					childGap = 16,
					childAlignment = {y = .Center},
				},
				backgroundColor = npub != "" && hovered() ? HOVER : PANEL,
				border = kb_focus == id ? kb_ring(ACCENT) : clay.BorderElementConfig{color = FIELD_BORDER, width = {1, 1, 1, 1, 0}},
				cornerRadius = rr(10),
			},
			) {
				agent_logo(i, 48)
				row_labels(connector.name, tr(connector.subtitle))
				clay.Text(
					ICON_RIGHT,
					{fontId = FONT_ICON, fontSize = 14, textColor = npub == "" ? TEXT_LO : ACCENT},
				)
			}
		}
	}
	clay.Text(
		tr(
			"These are installation prompts. Choose your agent, review its prompt, and paste it into that agent to connect it to White Noise. The prompt includes your public npub, never your private key, and asks the agent to explain the connector before requesting your approval to install it. Use only an agent you run and trust.",
		),
		{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
	)
	if clay.UI(clay.ID("AgentManual"))(settings_box()) {
		settings_group(tr("MANUAL SETUP"))
		if npub != "" {
			if clay.UI(clay.ID("AgentKeyRow"))(settings_row()) {
				row_labels(tr("Your public key"), npub_tail(npub))
				settings_button("AgentCopyKey", tr("Copy public key"))
			}
		}
		if clay.UI(clay.ID("AgentDocsRow"))(settings_row()) {
			row_labels(
				tr("Agent connector documentation"),
				tr("Install scripts, health checks, and troubleshooting."),
			)
			settings_button("AgentDocs", external_link_action())
		}
		clay.Text(
			tr(
				"Once the agent gives you its npub, use New chat to start a conversation with it. The connector documentation covers the rest.",
			),
			{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
		)
		clay.Text(
			tr(
				"Use a separate group for each project and start with its location and context. Session controls vary by connector; check its guide before using resume or branch commands.",
			),
			{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
		)
	}
}

@(private = "file")
agent_setup_view :: proc(ui: ^Ui_State, npub: string) {
	index := ui.agent_connector - 1
	connector := AGENT_CONNECTORS[index]
	width := settings_body_width(ui)
	settings_button("AgentBack", tr("Back to connectors"))
	if clay.UI(clay.ID("AgentHero"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(24),
			childGap = 20,
		},
		backgroundColor = PANEL,
		border = {color = fade(ACCENT, 0.5), width = {1, 1, 1, 1, 0}},
		cornerRadius = rr(12),
	},
	) {
		if clay.UI(clay.ID("AgentHeroIdentity"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 20,
				childAlignment = {y = .Center},
			},
		},
		) {
			agent_logo(index, width < 420 ? 56 : 72)
			if clay.UI(clay.ID("AgentHeroName"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					childGap = 7,
				},
			},
			) {
				clay.Text(
					fmt.tprintf(tr("Set up %s"), connector.name),
					{fontId = FONT_TITLE, fontSize = 26, textColor = TEXT},
				)
				clay.Text(
					tr(connector.subtitle),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
				)
			}
			if width >= 420 {
				clay.Text(ICON_RIGHT, {fontId = FONT_ICON, fontSize = 20, textColor = ACCENT})
				logo_mark()
			}
		}
		clay.Text(
			fmt.tprintf(
				tr("Paste this into %s. Review the installation plan before approving changes."),
				connector.name,
			),
			{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
		)
		if clay.UI(clay.ID("AgentHeroActions"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = width < 420 ? .TopToBottom : .LeftToRight,
				childGap = 16,
				childAlignment = {y = .Center},
			},
		},
		) {
			if clay.UI(clay.ID("AgentCopyPrompt"))(
			{
				layout = {
					sizing = {height = clay.SizingFixed(40)},
					padding = {left = 20, right = 20},
					childGap = 10,
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = hovered() ? ACCENT_DIM : ACCENT,
				border = kb_focus == "AgentCopyPrompt" ? kb_ring(TEXT) : {},
				cornerRadius = rr(8),
			},
			) {
				clay.Text(ICON_COPY, {fontId = FONT_ICON, fontSize = 14, textColor = ON_ACCENT})
				clay.Text(
					tr("Copy prompt"),
					{fontId = FONT_TITLE, fontSize = 14, textColor = ON_ACCENT},
				)
			}
			if clay.UI(clay.ID("AgentCopyKey"))(
			{
				layout = {
					sizing = {height = clay.SizingFixed(40)},
					padding = {left = 16, right = 16},
					childGap = 9,
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = hovered() ? HOVER : {},
				border = kb_focus == "AgentCopyKey" ? kb_ring(ACCENT) : clay.BorderElementConfig{color = FIELD_BORDER, width = {1, 1, 1, 1, 0}},
				cornerRadius = rr(8),
			},
			) {
				if hovered() {tooltip(npub)}
				clay.Text(ICON_COPY, {fontId = FONT_ICON, fontSize = 13, textColor = TEXT_DIM})
				clay.Text(
					tr("Copy public key"),
					{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
				)
			}
		}
		clay.Text(
			tr("Use only an agent you run and trust. Your private key is never included."),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
		)
	}
	if clay.UI(clay.ID("AgentGuideLinks"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = width < 420 ? .TopToBottom : .LeftToRight,
			childGap = 10,
		},
	},
	) {
		for guide, i in connector.guides {
			id := AGENT_REVIEW_CONTROLS[3 + i]
			if clay.UI(clay.ID(id))(
			{
				layout = {
					padding = {left = 12, right = 12, top = 8, bottom = 8},
					childGap = 8,
					childAlignment = {y = .Center},
				},
				backgroundColor = hovered() ? HOVER : ROW_BG,
				border = kb_focus == id ? kb_ring(ACCENT) : {},
				cornerRadius = rr(6),
			},
			) {
				if hovered() {tooltip(guide)}
				clay.Text(ICON_GLOBE, {fontId = FONT_ICON, fontSize = 12, textColor = ACCENT})
				clay.Text(
					guide == AGENT_CONNECTOR_DOCS ? tr("Connector guide") : fmt.tprintf(tr("%s guide"), connector.name),
					{fontId = FONT_BODY, fontSize = 12, textColor = TEXT},
				)
				clay.Text(ICON_RIGHT, {fontId = FONT_ICON, fontSize = 10, textColor = TEXT_DIM})
			}
		}
	}
	for section, i in agent_prompt_sections(index, npub) {
		if clay.UI(clay.ID("AgentInstruction", u32(i)))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				padding = clay.PaddingAll(20),
				childGap = 14,
			},
			backgroundColor = PANEL,
			border = {color = FIELD_BORDER, width = {1, 1, 1, 1, 0}},
			cornerRadius = rr(10),
		},
		) {
			if clay.UI(clay.ID_LOCAL("Heading"))(
			{layout = {childGap = 10, childAlignment = {y = .Center}}},
			) {
				if clay.UI(clay.ID_LOCAL("Step"))(
				{
					layout = {
						sizing = {clay.SizingFixed(25), clay.SizingFixed(25)},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = fade(ACCENT, 0.12),
					cornerRadius = rr(8),
				},
				) {
					clay.Text(
						fmt.tprintf("%02d", i + 1),
						{fontId = FONT_MONO, fontSize = 11, textColor = ACCENT},
					)
				}
				clay.Text(
					tr(section.label),
					{fontId = FONT_TITLE, fontSize = 16, textColor = TEXT},
				)
			}
			text, _ := strings.replace_all(
				section.text,
				npub,
				npub_tail(npub),
				context.temp_allocator,
			)
			agent_prompt_text(text, width - 40)
		}
	}
	clay.Text(
		tr(
			"Once the agent gives you its npub, use New chat to start a conversation with it. The connector documentation covers the rest.",
		),
		{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
	)
}

// Literal word wrapping keeps URLs and public keys from being treated as chat atoms.
@(private = "file")
agent_prompt_text :: proc(prompt: string, width: f32) {
	font := [1]u8{FONT_BODY | TEXT_CODE}
	fonts := strings.repeat(string(font[:]), len(prompt), context.temp_allocator)
	if clay.UI(clay.ID_LOCAL("Text"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childGap = 4,
		},
	},
	) {
		for at := 0; at < len(prompt); {
			cut := wrap_break(prompt, at, len(prompt), width, 13, fonts = fonts)
			clay.Text(
				prompt[at:cut],
				{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM, wrapMode = .None},
			)
			at = cut
			for at < len(prompt) && prompt[at] == ' ' {at += 1}
		}
	}
}

@(private)
handle_agents :: proc(ui: ^Ui_State) -> bool {
	npub := agent_public_key(ui)
	controls := AGENT_CONTROLS[:]
	if ui.agent_connector > 0 && ui.agent_connector <= len(AGENT_CONNECTORS) {
		controls = AGENT_REVIEW_CONTROLS[:3 + len(AGENT_CONNECTORS[ui.agent_connector - 1].guides)]
	} else if npub == "" {
		controls = AGENT_CONTROLS[len(AGENT_CONTROLS) - 1:]
	}
	action := ""
	if ui.focus != .SettingsSearch {
		switch control_keys(controls) {
		case .Moved:
			scroll_into_view(clay.ID("SettingsPage"), clay.ID(kb_focus))
			return true
		case .Pressed:
			action = kb_focus
		case .None:
		}
	}
	if action == "" && mouse_released() {
		for id in controls {
			if clicked(id) {action = id; break}
		}
	}
	if action == "" {return false}
	ui.focus = .Compose
	switch action {
	case "AgentDocs":
		open_link(ui, AGENT_CONNECTOR_DOCS)
	case "AgentGuide0", "AgentGuide1":
		index := action == "AgentGuide0" ? 0 : 1
		open_link(ui, AGENT_CONNECTORS[ui.agent_connector - 1].guides[index])
	case "AgentCopyKey":
		if npub != "" {copy_text(ui, npub, tr("Public key copied"))}
	case "AgentCopyPrompt":
		prompt := agent_setup_prompt(ui.agent_connector - 1, npub)
		if prompt != "" {copy_text(ui, prompt, tr("Prompt copied. Paste it into your agent."))}
	case "AgentBack":
		ui.agent_connector = 0
	case:
		if npub == "" {return true}
		for id, i in AGENT_CONTROLS[:len(AGENT_CONNECTORS)] {
			if id == action {ui.agent_connector = i + 1; break}
		}
	}
	if action == "AgentBack" ||
	   (ui.agent_connector > 0 &&
			   action != "AgentCopyPrompt" &&
			   action != "AgentCopyKey" &&
			   action != "AgentGuide0" &&
			   action != "AgentGuide1") {
		kb_focus = ""
		ui.settings_scroll_pending = true
	}
	return true
}
