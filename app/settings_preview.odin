package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
settings_conversation_preview :: proc(ui: ^Ui_State) {
	// Borrow only appearance preferences. No real chat, draft or signing key
	// enters the sample, and empty message IDs cannot trigger arrival effects.
	preview := Ui_State {
		selected       = -1,
		focus          = .Search,
		chat_preview_w = appearance_layout(ui).preview,
	}
	preview.prefs.centered_chat = ui.prefs.centered_chat
	preview.prefs.stt_enabled = ui.prefs.stt_enabled
	chat := Chat_Row_Ui {
		group_id   = "marmot-preview",
		avatar_key = "marmot-preview",
		title      = tr("Marmot meadow"),
	}
	// Sample afternoon stamps, on the clock the user picked.
	clock := [?]string {
		clock_text({hour = 14, minute = 2}, .Omit, context.temp_allocator),
		clock_text({hour = 14, minute = 3}, .Omit, context.temp_allocator),
		clock_text({hour = 14, minute = 4}, .Omit, context.temp_allocator),
		clock_text({hour = 14, minute = 5}, .Omit, context.temp_allocator),
	}
	messages := [?]Msg_Ui {
		{
			sender = "Pip",
			sender_id = "preview-pip",
			body = tr("Who put a sun lounger outside the burrow?"),
			at = clock[0],
			sort_at = 1,
		},
		{
			sender = "Maple",
			sender_id = "preview-maple",
			body = tr("I did. Very important marmot business."),
			at = clock[1],
			sort_at = 2,
		},
		{
			sender = "Maple",
			sender_id = "preview-maple",
			body = tr("Step one: find a warm rock. Step two: become one."),
			at = clock[1],
			sort_at = 3,
		},
		{
			sender = tr("You"),
			sender_id = "preview-you",
			mine = true,
			body = tr("I packed snacks for the expedition. 🥕"),
			at = clock[2],
			sort_at = 4,
			reply_from = "Pip",
			reply_text = tr("Who put a sun lounger outside the burrow?"),
		},
		{
			sender = "Pip",
			sender_id = "preview-pip",
			body = tr("Perfect. Wake me up when it's spring."),
			at = clock[3],
			sort_at = 5,
		},
	}
	for &message in messages {message.day = tr("Today")}

	previous := g_ui
	g_ui = &preview
	defer {g_ui = previous}
	preview_h := clamp(f32(rl.GetScreenHeight()) / UI_ZOOM * 0.7, f32(440), f32(620))
	if clay.UI(clay.ID("SettingsConversationPreview"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFit({min = preview_h})},
			layoutDirection = .TopToBottom,
		},
		backgroundColor = BG,
		border = {color = FIELD_BORDER, width = bw()},
		cornerRadius = rr(8),
	},
	) {
		if clay.UI(clay.ID("SettingsPreviewTitle"))(
		{layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(12)}},
		) {
			clay.Text(
				tr("Conversation preview"),
				{fontId = FONT_TITLE, fontSize = 14, textColor = TEXT},
			)
		}
		chat_pane(&preview, chat, messages[:])
	}
}
