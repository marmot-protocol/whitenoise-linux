package main

import marmot "../marmot"
import "core:strings"
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
