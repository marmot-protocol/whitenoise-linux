// One record fixture read by every surface: classification on its own,
// then search, mentions and the chat-list preview over the same records.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import marmot "../marmot"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
Fixture_Row :: struct {
	record: marmot.Timeline_Message_Record,
	class:  Record_Class,
}

// MDK hands the app projected rows: "original" already carries its newest
// accepted edit (record.edit), and the edit records are strays that an
// older store could still return. "hidden" is hidden locally.
@(private = "file")
fixture_rows :: proc(
	system: ^marmot.Group_System_Event,
	edit: ^marmot.Timeline_Edit_Summary,
) -> [13]Fixture_Row {
	return {
		{
			{
				message_id_hex = "original",
				sender = "alice",
				kind = KIND_CHAT_MESSAGE,
				plaintext = "**second** edit",
				edit = edit,
			},
			.Message,
		},
		{
			{
				message_id_hex = "edit-a",
				sender = "alice",
				kind = KIND_EDIT,
				plaintext = "first edit",
			},
			.Modifier,
		},
		{
			{
				message_id_hex = "edit-b",
				sender = "alice",
				kind = KIND_EDIT,
				plaintext = "**second** edit",
			},
			.Modifier,
		},
		{
			{
				message_id_hex = "forged",
				sender = "mallory",
				kind = KIND_EDIT,
				plaintext = "forged edit",
			},
			.Modifier,
		},
		{
			{
				message_id_hex = "vote",
				sender = "bob",
				kind = KIND_POLL_VOTE,
				plaintext = "vote payload",
			},
			.Modifier,
		},
		{
			{
				message_id_hex = "xdc",
				sender = "bob",
				kind = KIND_CHAT_MESSAGE,
				plaintext = "  wnxdc1:session:cGF5bG9hZA==",
			},
			.Webxdc,
		},
		{
			{
				message_id_hex = "hidden",
				sender = "bob",
				kind = KIND_CHAT_MESSAGE,
				plaintext = "hidden payload",
			},
			.Message,
		},
		{
			{
				message_id_hex = "thread",
				sender = "bob",
				kind = KIND_THREAD,
				plaintext = "thread *reply*",
			},
			.Message,
		},
		{
			{
				message_id_hex = "system",
				sender = "alice",
				kind = KIND_GROUP_SYSTEM,
				plaintext = `{"system_type":"group_renamed","name":"Ops"}`,
				group_system = system,
			},
			.System,
		},
		{
			{
				message_id_hex = "theme",
				sender = "bob",
				kind = THEME_EVENT_KIND,
				plaintext = `name = "payload"`,
			},
			.Theme,
		},
		{
			{
				message_id_hex = "agent",
				sender = "bob",
				kind = AGENT_ACTIVITY,
				plaintext = "agent payload",
			},
			.Agent_State,
		},
		{
			{
				message_id_hex = "stream",
				sender = "bob",
				kind = AGENT_STREAM_START,
				plaintext = "stream payload",
			},
			.Agent_Stream,
		},
		{
			{
				message_id_hex = "location",
				sender = "bob",
				kind = KIND_CHAT_MESSAGE,
				plaintext = "Location: https://maps.google.com/maps?q=51.5074,-0.1278",
			},
			.Message,
		},
	}
}

@(test)
record_classes :: proc(t: ^testing.T) {
	system: marmot.Group_System_Event
	edit: marmot.Timeline_Edit_Summary
	for row in fixture_rows(&system, &edit) {
		class := record_class(row.record.kind, string(row.record.plaintext))
		testing.expectf(t, class == row.class, "%s: %v", row.record.message_id_hex, class)
	}
}

@(test)
surfaces_read_effective_content :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("/tmp", "wn-message-content-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	deployment: ^marmot.Deployment
	if !testing.expect_value(
		t,
		marmot.deployment_white_noise(&deployment),
		marmot.Status.OK,
	) {return}
	defer marmot.deployment_free(deployment)
	client: ^marmot.Client
	store := vault_secret_store()
	if !testing.expect_value(
		t,
		marmot.client_new_with_secret_store(
			strings.clone_to_cstring(dir, context.temp_allocator),
			nil,
			0,
			&store,
			deployment,
			&client,
		),
		marmot.Status.OK,
	) {return}
	defer marmot.client_free(client)

	system := marmot.Group_System_Event {
		system_type        = "group_renamed",
		actor_display_name = "Alice",
		name               = "Ops",
	}
	edit := marmot.Timeline_Edit_Summary {
		edit_count = 2,
		latest_id  = "edit-b",
	}
	rows := fixture_rows(&system, &edit)

	// Search matches what the timeline shows. A system hit waits for its
	// sentence, which must itself match.
	for tc in ([]struct {
			input, id, snippet: string,
		}{{"second", "original", "second edit"}, {"**second", "", ""}, {"first edit", "", ""}, {"forged", "", ""}, {"renamed", "system", "Alice renamed the group to Ops"}, {"system_type", "", ""}, {"REPLY", "thread", "thread reply"}, {"location", "location", "Shared location"}, {"maps.google", "", ""}, {"payload", "", ""}}) {
		job := new(Search_Job)
		job.client, job.input = client, strings.clone(tc.input)
		job.hidden[strings.clone("hidden")] = true
		for &row in rows {
			hit := search_hit(job, "group", &row.record) or_continue
			append(&job.hits, hit)
		}
		search_phrase(job, client)
		if tc.id == "" {
			testing.expectf(t, len(job.hits) == 0, "%q: %v", tc.input, job.hits)
		} else if testing.expectf(t, len(job.hits) == 1, "%q: %v", tc.input, job.hits) {
			testing.expect_value(t, job.hits[0].msg_id, tc.id)
			testing.expect_value(t, job.hits[0].snippet, tc.snippet)
			testing.expect(t, job.hits[0].system == nil)
		}
		search_free(job)
	}

	// A mention counts where the text shows it, not inside a link target.
	account := "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	npub := hex_npub(account)
	defer delete(npub)
	mentions := [?]marmot.Timeline_Message_Record {
		{
			message_id_hex = "text",
			sender = "peer",
			kind = KIND_CHAT_MESSAGE,
			plaintext = fmt.ctprintf("**hi** nostr:%s", npub),
		},
		{
			message_id_hex = "link",
			sender = "peer",
			kind = KIND_CHAT_MESSAGE,
			plaintext = fmt.ctprintf("[profile](https://njump.me/%s)", npub),
		},
		{
			message_id_hex = "theme",
			sender = "peer",
			kind = THEME_EVENT_KIND,
			plaintext = fmt.ctprintf("name = \"nostr:%s\"", npub),
		},
	}
	page := marmot.Timeline_Page {
		messages     = raw_data(mentions[:]),
		messages_len = len(mentions),
	}
	job := new(Search_Job)
	job.client, job.kind, job.account = client, .Mentions, strings.clone(account)
	search_mentions_page(job, "group", &page)
	if testing.expect_value(t, len(job.hits), 1) {
		testing.expect_value(t, job.hits[0].msg_id, "text")
		testing.expect_value(t, job.hits[0].snippet, fmt.tprintf("hi %s", npub))
	}
	search_free(job)

	// A newest record that is not a message previews the newest one that is.
	window := [?]marmot.Timeline_Message_Record {
		rows[0].record,
		rows[5].record,
		rows[9].record,
		rows[11].record,
	}
	page = {
		messages     = raw_data(window[:]),
		messages_len = len(window),
	}
	last := marmot.Chat_List_Message_Preview {
		kind      = THEME_EVENT_KIND,
		plaintext = `name = "payload"`,
		sender    = "bob",
	}
	row := marmot.Chat_List_Row {
		group_id_hex = "group",
		last_message = &last,
	}
	preview, system_page := chat_row_preview(client, &row, "self", nil, &page, .Worker)
	testing.expect_value(t, preview, "second edit")
	testing.expect_value(t, system_page, nil)
}
