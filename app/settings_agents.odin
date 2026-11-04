package main

import "core:fmt"
import "core:strings"

import "nendo"
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
	for account in ui.accounts {
		if account.id_hex == ui.account_ref {
			if agent_key_valid(account.npub) {return account.npub}
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
	if nendo.box(nendo.id_local("BrandTile"))(
	{width = nendo.fixed(size), height = nendo.fixed(size), image = tex},
	) {}
}

@(private)
settings_agents :: proc(ui: ^Ui_State) {
	npub := agent_public_key(ui)
	if npub == "" {
		ui.agent_connector = 0
		nendo.text(
			tr("Your public key is unavailable. Choose another account and try again."),
			{font = FONT_BODY, size = 13, color = DANGER},
		)
	}
	if ui.agent_connector > 0 && ui.agent_connector <= len(AGENT_CONNECTORS) {
		agent_setup_view(ui, npub)
		return
	}

	nendo.text(
		tr("Connect an agent you run and trust."),
		{font = FONT_TITLE, size = 24, color = TEXT},
	)
	nendo.text(
		tr(
			"Chat with AI agents, end-to-end encrypted like any other chat. Each agent runs on a computer or server you control, using its own account.",
		),
		{font = FONT_BODY, size = 14, color = TEXT_DIM},
	)
	if nendo.box(nendo.id("AgentConnectors"))(
	{width = nendo.grow(), direction = .Column, gap = 10},
	) {
		for connector, i in AGENT_CONNECTORS {
			id := AGENT_CONTROLS[i]
			if nendo.box(nendo.id(id))(
			{
				width = nendo.grow(),
				padding = nendo.pad(16),
				gap = 16,
				align = {y = .Center},
				color = npub != "" && hovered() ? HOVER : PANEL,
				border = kb_focus == id ? kb_ring(ACCENT) : nendo.Border{color = FIELD_BORDER, width = {1, 1, 1, 1, 0}},
				radius = rr(10),
			},
			) {
				agent_logo(i, 48)
				row_labels(connector.name, tr(connector.subtitle))
				nendo.text(
					ICON_RIGHT,
					{font = FONT_ICON, size = 14, color = npub == "" ? TEXT_LO : ACCENT},
				)
			}
		}
	}
	nendo.text(
		tr(
			"These are installation prompts. Choose your agent, review its prompt, and paste it into that agent to connect it to White Noise. The prompt includes your public npub, never your private key, and asks the agent to explain the connector before requesting your approval to install it. Use only an agent you run and trust.",
		),
		{font = FONT_BODY, size = 12, color = TEXT_DIM},
	)
	if nendo.box(nendo.id("AgentManual"))(settings_box()) {
		settings_group(tr("MANUAL SETUP"))
		if npub != "" {
			if nendo.box(nendo.id("AgentKeyRow"))(settings_row()) {
				row_labels(tr("Your public key"), npub_tail(npub))
				settings_button("AgentCopyKey", tr("Copy public key"))
			}
		}
		if nendo.box(nendo.id("AgentDocsRow"))(settings_row()) {
			row_labels(
				tr("Agent connector documentation"),
				tr("Install scripts, health checks, and troubleshooting."),
			)
			settings_button("AgentDocs", external_link_action())
		}
		nendo.text(
			tr(
				"Once the agent gives you its npub, use New chat to start a conversation with it. The connector documentation covers the rest.",
			),
			{font = FONT_BODY, size = 13, color = TEXT_DIM},
		)
		nendo.text(
			tr(
				"Use a separate group for each project and start with its location and context. Session controls vary by connector; check its guide before using resume or branch commands.",
			),
			{font = FONT_BODY, size = 13, color = TEXT_DIM},
		)
	}
}

@(private = "file")
agent_setup_view :: proc(ui: ^Ui_State, npub: string) {
	index := ui.agent_connector - 1
	connector := AGENT_CONNECTORS[index]
	width := settings_body_width(ui)
	stacked := width < 420
	hero_inner := max(1, width - (stacked ? 24 : 48))
	settings_button("AgentBack", tr("Back to connectors"))
	if nendo.box(nendo.id("AgentHero"))(
	{
		width = nendo.fixed(width),
		direction = .Column,
		padding = stacked ? nendo.pad(12) : nendo.pad(24),
		gap = 20,
		color = PANEL,
		border = {color = fade(ACCENT, 0.5), width = {1, 1, 1, 1, 0}},
		radius = rr(12),
	},
	) {
		if nendo.box(nendo.id("AgentHeroIdentity"))(
		{
			width = nendo.fixed(hero_inner),
			direction = stacked ? .Column : .Row,
			gap = 20,
			align = {y = .Center},
		},
		) {
			agent_logo(index, stacked ? 56 : 72)
			if nendo.box(nendo.id("AgentHeroName"))(
			{

				// Reserve the connector, bridge and both gaps before wrapping the name.
				width     = nendo.fixed(stacked ? hero_inner : hero_inner - 72 - 79 - 40),
				direction = .Column,
				gap       = 7,
			},
			) {
				nendo.text(
					fmt.tprintf(tr("Set up %s"), connector.name),
					{font = FONT_TITLE, size = 26, color = TEXT},
				)
				nendo.text(tr(connector.subtitle), {font = FONT_BODY, size = 13, color = TEXT_DIM})
			}
			if nendo.box(nendo.id("AgentHeroBridge"))(
			{width = nendo.fixed(79), gap = 20, align = {y = .Center}},
			) {
				nendo.text(ICON_RIGHT, {font = FONT_ICON, size = 20, color = ACCENT})
				logo_mark()
			}
		}
		nendo.text(
			fmt.tprintf(
				tr("Paste this into %s. Review the installation plan before approving changes."),
				connector.name,
			),
			{font = FONT_BODY, size = 14, color = TEXT_DIM},
		)
		if nendo.box(nendo.id("AgentHeroActions"))(
		{
			width = nendo.grow(),
			direction = width < 420 ? .Column : .Row,
			gap = 16,
			align = {y = .Center},
		},
		) {
			if nendo.box(nendo.id("AgentCopyPrompt"))(
			{
				height = nendo.fixed(settings_tap_size(40)),
				padding = {left = 20, right = 20},
				gap = 10,
				align = {x = .Center, y = .Center},
				color = hovered() ? ACCENT_DIM : ACCENT,
				border = kb_focus == "AgentCopyPrompt" ? kb_ring(TEXT) : {},
				radius = rr(8),
			},
			) {
				nendo.text(ICON_COPY, {font = FONT_ICON, size = 14, color = ON_ACCENT})
				nendo.text(tr("Copy prompt"), {font = FONT_TITLE, size = 14, color = ON_ACCENT})
			}
			if nendo.box(nendo.id("AgentCopyKey"))(
			{
				height = nendo.fixed(settings_tap_size(40)),
				padding = {left = 16, right = 16},
				gap = 9,
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : {},
				border = kb_focus == "AgentCopyKey" ? kb_ring(ACCENT) : nendo.Border{color = FIELD_BORDER, width = {1, 1, 1, 1, 0}},
				radius = rr(8),
			},
			) {
				if hovered() {tooltip(npub)}
				nendo.text(ICON_COPY, {font = FONT_ICON, size = 13, color = TEXT_DIM})
				nendo.text(tr("Copy public key"), {font = FONT_BODY, size = 14, color = TEXT_DIM})
			}
		}
		nendo.text(
			tr("Use only an agent you run and trust. Your private key is never included."),
			{font = FONT_BODY, size = 11, color = TEXT_DIM},
		)
	}
	if nendo.box(nendo.id("AgentGuideLinks"))(
	{width = nendo.grow(), direction = width < 420 ? .Column : .Row, gap = 10},
	) {
		for guide, i in connector.guides {
			id := AGENT_REVIEW_CONTROLS[3 + i]
			if nendo.box(nendo.id(id))(
			{
				height = nendo.fit(min = settings_tap_size(32)),
				padding = {left = 12, right = 12, top = 8, bottom = 8},
				gap = 8,
				align = {y = .Center},
				color = hovered() ? HOVER : ROW_BG,
				border = kb_focus == id ? kb_ring(ACCENT) : {},
				radius = rr(6),
			},
			) {
				if hovered() {tooltip(guide)}
				nendo.text(ICON_GLOBE, {font = FONT_ICON, size = 12, color = ACCENT})
				nendo.text(
					guide == AGENT_CONNECTOR_DOCS ? tr("Connector guide") : fmt.tprintf(tr("%s guide"), connector.name),
					{font = FONT_BODY, size = 12, color = TEXT},
				)
				nendo.text(ICON_RIGHT, {font = FONT_ICON, size = 10, color = TEXT_DIM})
			}
		}
	}
	for section, i in agent_prompt_sections(index, npub) {
		if nendo.box(nendo.id("AgentInstruction", u32(i)))(
		{
			width = nendo.grow(),
			direction = .Column,
			padding = nendo.pad(20),
			gap = 14,
			color = PANEL,
			border = {color = FIELD_BORDER, width = {1, 1, 1, 1, 0}},
			radius = rr(10),
		},
		) {
			if nendo.box(nendo.id_local("Heading"))(
			{width = nendo.grow(), gap = 10, align = {y = .Center}},
			) {
				if nendo.box(nendo.id_local("Step"))(
				{
					width = nendo.fixed(25),
					height = nendo.fixed(25),
					align = {x = .Center, y = .Center},
					color = fade(ACCENT, 0.12),
					radius = rr(8),
				},
				) {
					nendo.text(
						fmt.tprintf("%02d", i + 1),
						{font = FONT_MONO, size = 11, color = ACCENT},
					)
				}
				nendo.text(tr(section.label), {font = FONT_TITLE, size = 16, color = TEXT})
			}
			agent_prompt_text(section.text, width - 40)
		}
	}
	nendo.text(
		tr(
			"Once the agent gives you its npub, use New chat to start a conversation with it. The connector documentation covers the rest.",
		),
		{font = FONT_BODY, size = 12, color = TEXT_DIM},
	)
}

// Literal word wrapping keeps URLs and public keys from being treated as chat atoms.
@(private = "file")
agent_prompt_text :: proc(prompt: string, width: f32) {
	font := [1]u8{FONT_BODY | TEXT_CODE}
	fonts := strings.repeat(string(font[:]), len(prompt), context.temp_allocator)
	if nendo.box(nendo.id_local("Text"))({width = nendo.grow(), direction = .Column, gap = 4}) {
		for at := 0; at < len(prompt); {
			cut := wrap_break(prompt, at, len(prompt), width, 13, fonts = fonts)
			nendo.text(
				prompt[at:cut],
				{font = FONT_BODY, size = 13, color = TEXT_DIM, wrap = .None},
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
			scroll_into_view(nendo.id("SettingsPage"), nendo.id(kb_focus))
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
