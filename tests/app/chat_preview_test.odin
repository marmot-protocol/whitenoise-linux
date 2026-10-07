package main

import marmot "../marmot"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:unicode/utf8"

@(test)
chat_hidden_preview :: proc(t: ^testing.T) {
	secret := secret_fixture(strings.repeat("secret ", 6000, context.temp_allocator))
	text := strings.concatenate({"You: 🦂", secret}, context.temp_allocator)
	testing.expect_value(t, chat_preview(text), "You: 🦂")
	last := marmot.Chat_List_Message_Preview {
		plaintext = strings.clone_to_cstring(text, context.temp_allocator),
		kind      = 9,
	}
	row := marmot.Presented_Chat_Row {
		row = {group_id_hex = "group", last_message = &last},
	}
	chat := row_to_ui(nil, &row, "self")
	defer chat_free(chat)
	testing.expect_value(t, chat.preview, "You: 🦂")
	for text in ([]string{strings.repeat("日", 200, context.temp_allocator), strings.concatenate({"🦂", strings.repeat("\u200d", 1024 * 1024, context.temp_allocator)}, context.temp_allocator)}) {
		preview := chat_preview(text)
		testing.expect(t, len(preview) <= 259)
		testing.expect(t, utf8.valid_string(preview))
		testing.expect(t, strings.has_suffix(preview, "…"))
	}
	testing.expect_value(t, chat_preview("👩🏽‍💻 hello"), "👩🏽‍💻 hello")
}

@(test)
chat_markdown_reading_preview :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous_ui := g_ui
	defer {g_ui = previous_ui}
	ui: Ui_State
	ui.blocked = make(map[string]bool, context.temp_allocator)
	ui.blocked["blocked"] = true
	g_ui = &ui
	dir, err := os.make_directory_temp("/tmp", "wn-chat-preview-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	client: ^marmot.Client
	store := vault_secret_store()
	if !testing.expect_value(
		t,
		marmot.client_new_with_secret_store(
			strings.clone_to_cstring(dir, context.temp_allocator),
			nil,
			0,
			&store,
			&client,
		),
		marmot.Status.OK,
	) {return}
	defer marmot.client_free(client)
	for tc in ([]struct {
			body, want: string,
		}{{"**not-bold** and [a link](https://example.com)", "not-bold and a link"}, {"# Heading\n\nFirst *paragraph*.\n\n> Quoted **words**\n\n- one\n- two\n\n```text\n**literal** [code](url)\n```", "Heading First paragraph. Quoted words one two **literal** [code](url)"}, {"first  \nsecond\n\n`**inline code**`", "first second **inline code**"}, {"| **Name** | Value |\n| --- | --- |\n| [label](https://example.com) | `raw()` |", "Name Value label raw()"}, {strings.concatenate({"**Visible**", secret_fixture("[hidden payload](https://secret.example)")}, context.temp_allocator), "Visible"}, {secret_fixture("**Only hidden payload**"), ""}, {strings.concatenate({"[", strings.repeat("日", 100, context.temp_allocator), "](https://example.com)"}, context.temp_allocator), strings.concatenate({strings.repeat("日", 85, context.temp_allocator), "…"}, context.temp_allocator)}}) {
		for sender in ([]cstring{"peer", "self"}) {
			last := marmot.Chat_List_Message_Preview {
				plaintext = strings.clone_to_cstring(tc.body, context.temp_allocator),
				sender    = sender,
				kind      = 9,
			}
			row := marmot.Presented_Chat_Row {
				row = {group_id_hex = "group", last_message = &last},
			}
			preview := row_to_ui(client, &row, "self")
			want := tc.want
			if sender == "self" && want != "" {
				// The sent prefix participates in the UTF-8 byte cap.
				if strings.has_suffix(want, "…") {
					want = strings.concatenate(
						{"You: ", strings.repeat("日", 83, context.temp_allocator), "…"},
						context.temp_allocator,
					)
				} else {
					want = strings.concatenate({"You: ", want}, context.temp_allocator)
				}
			}
			testing.expect_value(t, preview.preview, want)
			testing.expect(t, utf8.valid_string(preview.preview))
			chat_free(preview)
			// UI adoption consumes a prepared worker snapshot, including empty
			// entries, without parsing the retained source again.
			prepared, _ := chat_row_preview(client, &row.row, "self", nil)
			previews := make(map[string]string, context.temp_allocator)
			previews["group"] = prepared
			last.plaintext = "**not the prepared preview**"
			adopted := row_to_ui(nil, &row, "self", nil, previews)
			testing.expect_value(t, adopted.preview, want)
			chat_free(adopted)
		}
	}
	// A blocked newest message falls back to reading text from the same
	// bounded timeline window, skipping payloads that the timeline hides.
	records := [?]marmot.Timeline_Message_Record {
		{
			kind = 9,
			plaintext = "**older** [link](https://example.com)",
			direction = "sent",
			sender = "self",
		},
		{
			kind = 9,
			plaintext = strings.clone_to_cstring(secret_fixture("hidden"), context.temp_allocator),
			sender = "peer",
		},
		{kind = KIND_POLL_VOTE, plaintext = "vote payload", sender = "peer"},
		{kind = 9, plaintext = "blocked newest text", sender = "blocked"},
	}
	page := marmot.Timeline_Page {
		messages     = raw_data(records[:]),
		messages_len = len(records),
	}
	last := marmot.Chat_List_Message_Preview {
		kind      = 9,
		plaintext = "blocked newest text",
		sender    = "blocked",
	}
	row := marmot.Presented_Chat_Row {
		row = {group_id_hex = "fallback", last_message = &last},
	}
	prepared, system_page := chat_row_preview(client, &row.row, "self", ui.blocked, &page, .Worker)
	testing.expect_value(t, prepared, "You: older link")
	testing.expect_value(t, system_page, nil)
	previews := make(map[string]string, context.temp_allocator)
	previews["fallback"] = prepared
	fallback := row_to_ui(nil, &row, "self", nil, previews)
	testing.expect_value(t, fallback.preview, "You: older link")
	chat_free(fallback)
	// A fallback system is retained for the existing UI label resolver,
	// rather than resolving profile/UI state on the worker.
	system := marmot.Group_System_Event {
		system_type          = "member_added",
		actor_display_name   = "Alice",
		subject_display_name = "Bob",
	}
	records[2] = {
		kind         = 1210,
		group_system = &system,
	}
	prepared, system_page = chat_row_preview(client, &row.row, "self", ui.blocked, &page, .Worker)
	testing.expect_value(t, system_page, &page)
	pages := make(map[string]^marmot.Timeline_Page, context.temp_allocator)
	pages["fallback"] = system_page
	summary := row_to_ui(nil, &row, "self", pages)
	testing.expect_value(t, summary.preview, "Alice added Bob")
	chat_free(summary)
}

@(test)
chat_blocked_and_system_preview :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous_ui := g_ui
	defer {g_ui = previous_ui}
	ui: Ui_State
	ui.blocked = make(map[string]bool, context.temp_allocator)
	ui.blocked["blocked"] = true
	g_ui = &ui
	last := marmot.Chat_List_Message_Preview {
		plaintext = "private blocked text",
		sender    = "blocked",
		kind      = 9,
	}
	row := marmot.Presented_Chat_Row {
		row = {group_id_hex = "group", last_message = &last},
	}
	blocked := row_to_ui(nil, &row, "self")
	testing.expect_value(t, blocked.preview, "")
	testing.expect(t, blocked.last_blocked)
	chat_free(blocked)
	// A sent message is not hidden by a blocked entry for its own account.
	last.sender = "self"
	ui.blocked["self"] = true
	mine := row_to_ui(nil, &row, "self")
	testing.expect_value(t, mine.preview, "You: private blocked text")
	chat_free(mine)
	system := marmot.Group_System_Event {
		system_type        = "group_renamed",
		actor_display_name = "Alice",
		name               = "**literal group name**",
	}
	last.kind = 1210
	last.group_system = &system
	last.plaintext = "{\"system\":\"payload\"}"
	summary := row_to_ui(nil, &row, "self")
	testing.expect_value(t, summary.preview, "Alice renamed the group to **literal group name**")
	chat_free(summary)
}

@(test)
chat_audio_preview :: proc(t: ^testing.T) {
	for tc in ([]struct {
			body, sender:      cstring,
			kind:              i32,
			has_kind, deleted: bool,
			want:              string,
		}{{"", "self", CHAT_ATTACHMENT_AUDIO, true, false, "You: Audio message"}, {nil, "self", CHAT_ATTACHMENT_AUDIO, true, false, "You: Audio message"}, {"  \n", "peer", CHAT_ATTACHMENT_AUDIO, true, false, "Audio message"}, {"Listen to this", "self", CHAT_ATTACHMENT_AUDIO, true, false, "You: Listen to this"}, {"", "self", CHAT_ATTACHMENT_AUDIO, false, false, ""}, {"", "self", CHAT_ATTACHMENT_AUDIO, true, true, ""}, {"", "self", 0, true, false, ""}}) {
		last := marmot.Chat_List_Message_Preview {
			plaintext           = tc.body,
			sender              = tc.sender,
			kind                = 9,
			attachment_kind     = tc.kind,
			has_attachment_kind = tc.has_kind,
			deleted             = tc.deleted,
		}
		row := marmot.Presented_Chat_Row {
			row = {group_id_hex = "group", last_message = &last},
		}
		ui := row_to_ui(nil, &row, "self")
		testing.expect_value(t, ui.preview, tc.want)
		chat_free(ui)
	}
}

@(test)
chat_selected_presentation :: proc(t: ^testing.T) {
	last := marmot.Chat_List_Message_Preview {
		plaintext = "Hello",
		sender    = "peer",
		kind      = 9,
	}
	row := marmot.Presented_Chat_Row {
		row = {
			group_id_hex = "98d2a13e5226783d4",
			title = "98d2a13e5226783d4",
			conversation_kind = .DIRECT,
			pending_confirmation = true,
			last_message = &last,
		},
	}
	row.presentation.title = {
		tag = .Literal,
		body = {literal = "Upbeat Wolf"},
	}
	row.presentation.peer_id = "peer-public-key"
	row.presentation.avatar = {
		tag = .Remote_Image,
		body = {remote = {url = "https://example.org/wolf.png"}},
	}
	invite := row_to_ui(nil, &row, "self")
	defer chat_free(invite)
	testing.expect_value(t, invite.title, "Upbeat Wolf")
	testing.expect_value(t, invite.avatar_key, "peer-public-key")
	testing.expect_value(t, invite.avatar_url, "https://example.org/wolf.png")
	testing.expect_value(t, invite.preview, "Hello")
	testing.expect(t, invite.pending)

	// The selected presentation also preserves named groups and encrypted avatars.
	row.presentation.title.body.literal = "Named group"
	row.row.conversation_kind = .GROUP
	row.presentation.avatar = {
		tag = .Encrypted_Group_Image,
		body = {encrypted = {image = {image_hash_hex = "image-hash"}}},
	}
	group := row_to_ui(nil, &row, "self")
	defer chat_free(group)
	testing.expect_value(t, group.title, "Named group")
	testing.expect_value(t, group.avatar_key, string(row.row.group_id_hex))
	testing.expect_value(t, group.image_hash, "image-hash")
	testing.expect_value(t, group.avatar_url, "")

	row.presentation.avatar = {
		tag = .Placeholder,
	}
	for title in ([]marmot.Presentation_Text{{tag = .Unnamed_Group}, {tag = .Unavailable_Conversation}}) {
		row.presentation.title = title
		fallback := row_to_ui(nil, &row, "self")
		testing.expect_value(
			t,
			fallback.title,
			title.tag == .Unnamed_Group ? tr("Unnamed group") : tr("Unavailable conversation"),
		)
		testing.expect_value(t, fallback.avatar_url, "")
		testing.expect_value(t, fallback.image_hash, "")
		chat_free(fallback)
	}
}
