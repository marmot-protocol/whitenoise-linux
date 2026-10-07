package main

import "core:fmt"
import "core:strings"

@(private)
Agent_Connector :: struct {
	name, subtitle, prompt: string,
	guides:                 []string,
}

@(private)
Agent_Prompt_Section :: struct {
	label, text: string,
}

@(private)
AGENT_CONNECTOR_DOCS :: "https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md"

@(private)
AGENT_CONNECTORS := []Agent_Connector {
	{
		name = "Hermes",
		subtitle = N_("Terminal agent by Nous Research"),
		guides = {
			"https://github.com/marmot-protocol/mdk/blob/master/integrations/hermes/marmot/README.md",
			AGENT_CONNECTOR_DOCS,
		},
		prompt = N_(
			"This is an installation prompt for connecting this Hermes installation to White Noise through Marmot. Read the latest connector guide at https://github.com/marmot-protocol/mdk/blob/master/integrations/hermes/marmot/README.md / https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md. Explain to me how the connector works and what the installation will change. Then propose the installation steps for my public npub: %s, and ask for my approval before making any changes. Once I approve, install and verify the connector, then reply with your agent npub. Before proposing changes, confirm the intended Hermes profile, Hermes home, Marmot home/socket, agent account and service, and gateway instance; do not assume the default profile or overwrite another installation. Use the checksum-verified Hermes installer flow. Distinguish invite authorization from message-sender authorization. Guide me through the invitation from my current account in the White Noise app and a test message, and verify that the selected profile replies in White Noise before calling pairing complete.",
		),
	},
	{
		name = "OpenClaw",
		subtitle = N_("Self-hosted personal AI assistant"),
		guides = {AGENT_CONNECTOR_DOCS},
		prompt = N_(
			"This is an installation prompt for connecting this OpenClaw instance to White Noise through Marmot. Read the latest connector guide at https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md. Explain to me how the connector works and what the installation will change. Then propose the installation steps for my public npub: %s, and ask for my approval before making any changes. Once I approve, install and verify the connector, then reply with your agent npub.",
		),
	},
	{
		name = "OpenCode",
		subtitle = N_("Open-source coding agent"),
		guides = {AGENT_CONNECTOR_DOCS},
		prompt = N_(
			"This is an installation prompt for connecting this OpenCode setup to White Noise through Marmot. Read the latest connector guide at https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md. Explain to me how the connector works and what the installation will change. Then propose the installation steps for my public npub: %s, and ask for my approval before making any changes. Once I approve, install and verify the connector, then reply with your agent npub.",
		),
	},
	{
		name = "Codex",
		subtitle = N_("OpenAI Codex CLI coding agent"),
		guides = {
			"https://github.com/marmot-protocol/mdk/blob/master/integrations/codex/marmot/README.md",
			AGENT_CONNECTOR_DOCS,
		},
		prompt = N_(
			"This is an installation prompt for connecting this Codex setup to White Noise through Marmot. Read the authoritative Codex harness guide at https://github.com/marmot-protocol/mdk/blob/master/integrations/codex/marmot/README.md and the evergreen connector guide at https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md. Explain to me how the connector works and what the installation will change. Confirm prerequisites: Codex CLI is installed, authenticated, and available on PATH, and this machine uses the same public relay set as my current account in the White Noise app. Then propose the installation steps for my public npub: %s, and ask for my approval before making any changes. Once I approve, use the checksum-verified install-codex-marmot.sh release flow, bootstrap wn-agent for that npub with the allowed welcomer, and verify wn-codex --version. Then reply with your agent npub and ask me to invite it from White Noise and send a test message from this allowed npub over the configured relays. Do not report setup complete until wn-codex returns a reply through White Noise; if that round trip cannot be verified automatically, clearly mark device verification required.",
		),
	},
	{
		name = "Claude Code",
		subtitle = N_("Claude Code CLI coding agent"),
		guides = {
			"https://github.com/marmot-protocol/mdk/blob/master/integrations/claude/marmot/README.md",
			AGENT_CONNECTOR_DOCS,
		},
		prompt = N_(
			"This is an installation prompt for connecting this Claude Code setup to White Noise through Marmot. Read the authoritative Claude Code harness guide at https://github.com/marmot-protocol/mdk/blob/master/integrations/claude/marmot/README.md and the evergreen connector guide at https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md. Explain to me how the connector works and what the installation will change. Confirm prerequisites: Claude Code CLI is installed, authenticated, and available on PATH, and this machine uses the same public relay set as my current account in the White Noise app. Then propose the installation steps for my public npub: %s, and ask for my approval before making any changes. Once I approve, use the checksum-verified install-claude-marmot.sh release flow, bootstrap wn-agent for that npub with the allowed welcomer, and verify wn-claude --version. Then reply with your agent npub and ask me to invite it from White Noise and send a test message from this allowed npub over the configured relays. Do not report setup complete until wn-claude returns a reply through White Noise; if that round trip cannot be verified automatically, clearly mark device verification required.",
		),
	},
}

@(private)
agent_key_valid :: proc(npub: string) -> bool {
	if len(npub) != 63 {return false}
	hrp, key, ok := bech32_decode(npub)
	return ok && hrp == "npub" && len(key) == 32
}

@(private)
agent_setup_prompt :: proc(index: int, npub: string) -> string {
	if index < 0 || index >= len(AGENT_CONNECTORS) || !agent_key_valid(npub) {return ""}
	return fmt.tprintf(tr(AGENT_CONNECTORS[index].prompt), npub)
}

@(private)
agent_prompt_sections :: proc(index: int, npub: string) -> (sections: [2]Agent_Prompt_Section) {
	prompt := agent_setup_prompt(index, npub)
	if prompt == "" {return}

	key_end := strings.index(prompt, npub) + len(npub)
	intro_end, review_end := 0, len(prompt)
	sentences := 0
	// Periods inside guide URLs are not sentence boundaries. Rune iteration
	// keeps the Japanese full stop intact when slicing the translated prompt.
	for r, at in prompt {
		end := at + 1
		if r == '。' {
			end = at + len("。")
		} else if r != '.' || (end < len(prompt) && prompt[end] > ' ') {
			continue
		}
		sentences += 1
		if sentences == 2 {intro_end = end}
		if sentences > 2 && end >= key_end {
			review_end = end
			break
		}
	}

	sections[0] = {N_("Review and approve"), strings.trim_space(prompt[intro_end:review_end])}
	sections[1] = {N_("Install and verify"), strings.trim_space(prompt[review_end:])}
	return sections
}
