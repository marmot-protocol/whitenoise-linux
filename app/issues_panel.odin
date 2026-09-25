package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:fmt"
import "core:strings"
import rl "sdlrl"

@(private)
Issue_Action :: enum {
	Setting,
	Create,
	Status,
}
@(private)
ISSUE_STATUS_NAMES := [3]string{N_("Unresolved"), N_("Resolved"), N_("Closed")}

@(private)
issues_settings :: proc(ui: ^Ui_State) {
	eyebrow("ISSUE TRACKING")
	if ui.issue_ticket != 0 && ui.issue_action == .Setting {
		clay.Text(
			tr("Updating issue tracking..."),
			{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
		)
	} else if ui.issue_setting == .Unavailable {
		clay.Text(
			tr("Issue tracking is unavailable."),
			{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
		)
		micro_button("IssueRetry", "Retry")
	} else {
		clay.Text(
			ui.issue_setting == .Enabled ? tr("Enabled for this group.") : tr("Disabled for this group."),
			{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
		)
		if ui.issue_admin {
			micro_button(
				"IssueToggle",
				ui.issue_setting == .Enabled ? tr("Disable issue tracking") : tr("Enable issue tracking"),
			)
		} else {
			clay.Text(
				tr("Only group admins can change this setting."),
				{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_LO},
			)
		}
	}
}

@(private)
issues_select :: proc(ui: ^Ui_State, client: ^marmot.Client, id: string) {
	selected := strings.clone(id)
	delete(ui.issue_selected)
	ui.issue_selected = selected
	issues_sync_route(ui, client)
	blocks_free(ui.issue_blocks); ui.issue_blocks = {}
	slot, found := ui.issue_index[selected]
	if !found || issue_page == nil {return}
	record := &issue_page.items[ui.issues[slot].record]
	doc: ^marmot.Markdown_Document
	if marmot.parse_markdown(client, record.plaintext, &doc) == .OK {
		convert_blocks(
			&ui.issue_blocks,
			doc.blocks,
			doc.blocks_len,
			false,
			([^]u8)(doc.blank_lines_before)[:doc.blank_lines_before_len],
		)
		marmot.markdown_document_free(doc)
	}
}

@(private)
issue_button :: proc(id, label: string) {
	if clay.UI(clay.ID(id))(
	{
		layout = {
			padding = {left = 14, right = 14, top = 9, bottom = 9},
			childAlignment = {x = .Center},
		},
		backgroundColor = hovered() ? ACCENT_HI : ACCENT,
		cornerRadius = rr(7),
	},
	) {
		clay.Text(label, {fontId = FONT_BODY, fontSize = 13, textColor = ON_ACCENT})
	}
}

@(private)
issue_author :: proc(ui: ^Ui_State, record: ^marmot.App_Message_Record, index: u32) {
	sender := string(record.sender)
	info := profile_info(g_client, sender)
	stamp: string
	{context.allocator = context.temp_allocator; stamp = format_full(record.recorded_at)}
	name :=
		sender == ui.account_ref ? tr("You") : info.name != "" ? info.name : sender[:min(12, len(sender))]
	if clay.UI(clay.ID("IssueAuthor", index))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			childGap = 10,
			childAlignment = {y = .Center},
		},
	},
	) {
		avatar("IssueAvatar", index, sender, name, 28, url_pic(info.pic_url))
		if clay.UI(clay.ID("IssueByline", index))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = 3,
			},
		},
		) {
			clay.Text(name, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
			clay.Text(stamp, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
		}
	}
}

@(private)
issues_panel :: proc(ui: ^Ui_State) {
	narrow := page_w(ui) < 720
	detail := ui.issue_new || ui.issue_selected != ""
	if !narrow || !detail {
		if clay.UI(clay.ID("IssueSidebar"))(
		{
			layout = {
				sizing = {narrow ? clay.SizingGrow() : clay.SizingFixed(300), clay.SizingGrow()},
				layoutDirection = .TopToBottom,
			},
			backgroundColor = RAIL_BG,
			border = {color = DIVIDER, width = {right = 1}},
		},
		) {
			if clay.UI(clay.ID("IssueTools"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					padding = clay.PaddingAll(18),
					childGap = 16,
				},
			},
			) {
				if clay.UI(clay.ID("IssueHeading"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						childAlignment = {y = .Center},
						childGap = 10,
					},
				},
				) {
					clay.Text(tr("Issues"), {fontId = FONT_TITLE, fontSize = 20, textColor = TEXT})
					clay.Text(
						fmt.tprintf("%d", len(ui.issues)),
						{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_LO},
					)
					if clay.UI(clay.ID("IssueHeadingSpace"))(
					{layout = {sizing = {width = clay.SizingGrow()}}},
					) {}
					issue_button("IssueNew", tr("New issue"))
				}
				input_box(
					ui,
					"IssueSearch",
					&ui.issue_search,
					tr("Search issues"),
					ui.focus == .Issue_Search,
					0,
				)
				names := [4]string{N_("All"), N_("Unresolved"), N_("Resolved"), N_("Closed")}
				if clay.UI(clay.ID("IssueFilterToggle"))(
				{
					layout = {
						padding = {top = 3, bottom = 3},
						childGap = 8,
						childAlignment = {y = .Center},
					},
				},
				) {
					clay.Text(
						tr(names[ui.issue_filter]),
						{
							fontId = FONT_BODY,
							fontSize = 12,
							textColor = hovered() ? TEXT : TEXT_DIM,
						},
					)
					clay.Text("⌄", {fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM})
					if ui.issue_filter_open {
						if clay.UI(clay.ID("IssueFilterMenu"))(
						{
							layout = {
								sizing = {width = clay.SizingFixed(180)},
								padding = clay.PaddingAll(5),
								layoutDirection = .TopToBottom,
							},
							backgroundColor = CARD,
							cornerRadius = rr(8),
							border = {color = ELEVATED_BORDER, width = bw()},
							floating = {
								attachTo = .Parent,
								zIndex = 10,
								offset = {0, 6},
								attachment = {element = .LeftTop, parent = .LeftBottom},
							},
						},
						) {for name, i in names {ctx_item(fmt.tprintf("IssueFilter%d", i), ui.issue_filter == i ? ICON_CHECK : "", tr(name))}}
					}
				}
			}
			if clay.UI(clay.ID("IssueList"))(
			{
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					padding = {left = 8, right = 8},
					childGap = 2,
				},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
			},
			) {
				count := 0
				query := strings.to_lower(string(ui.issue_search[:]), context.temp_allocator)
				for row, i in ui.issues {
					record := &issue_page.items[row.record]
					title := issue_tag(record.tags[:record.tags_len], "subject")
					if ui.issue_filter > 0 && int(row.status) + 1 != ui.issue_filter {continue}
					if query != "" &&
					   !strings.contains(
							   strings.to_lower(
								   fmt.tprintf("%s %s", title, string(record.plaintext)),
								   context.temp_allocator,
							   ),
							   query,
						   ) {continue}
					count += 1
					selected := !ui.issue_new && ui.issue_selected == row.id
					if clay.UI(clay.ID("IssueRow", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							padding = clay.PaddingAll(12),
							childGap = 10,
						},
						backgroundColor = selected ? SELECTED : hovered() ? HOVER : {},
						cornerRadius = rr(6),
					},
					) {
						crop_circle("IssueIdentity", u32(i), row.id, 32)
						if clay.UI(clay.ID("IssueRowCopy", u32(i)))(
						{
							layout = {
								sizing = {width = clay.SizingGrow()},
								layoutDirection = .TopToBottom,
								childGap = 8,
							},
						},
						) {
							clay.Text(
								title,
								{fontId = FONT_TITLE, fontSize = 14, textColor = TEXT},
							)
							if clay.UI(clay.ID("IssueRowMeta", u32(i)))(
							{
								layout = {
									sizing = {width = clay.SizingGrow()},
									childGap = 5,
									childAlignment = {y = .Center},
								},
							},
							) {
								clay.Text(
									tr(ISSUE_STATUS_NAMES[row.status]),
									{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
								)
								if clay.UI(clay.ID("IssueRowSpace", u32(i)))(
								{layout = {sizing = {width = clay.SizingGrow()}}},
								) {}
								clay.Text(
									ICON_COMMENTS,
									{fontId = FONT_ICON, fontSize = 10, textColor = TEXT_LO},
								)
								clay.Text(
									fmt.tprintf("%d", len(row.comments)),
									{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
								)
							}
						}
					}
				}
				if count == 0 {
					if clay.UI(clay.ID("IssueEmptyList"))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							padding = clay.PaddingAll(16),
						},
					},
					) {
						clay.Text(
							tr("No issues found."),
							{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
						)
					}
				}
			}
			scrollbar(clay.ID("IssueList"))
			if clay.UI(clay.ID("IssueSidebarFooter"))(
			{
				layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(16)},
				border = {color = DIVIDER, width = {top = 1}},
			},
			) {micro_button("IssueClose", "Back to chat")}
		}
	}
	if narrow && !detail {return}
	pad: u16 = narrow ? 20 : 32
	width := max(f32(100), page_w(ui) - (narrow ? 0 : 300) - f32(pad * 2))
	if clay.UI(clay.ID("IssueDetail"))(
	{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}},
	) {
		if narrow && detail {
			if clay.UI(clay.ID("IssueNavigation"))(
			{layout = {padding = {left = pad, right = pad, top = 12}}},
			) {micro_button("IssueBack", "Back to issues")}
		}
		if ui.issue_new {
			if clay.UI(clay.ID("IssueForm"))(
			{
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					padding = clay.PaddingAll(pad),
					childGap = 18,
				},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
			},
			) {
				clay.Text(tr("New issue"), {fontId = FONT_TITLE, fontSize = 24, textColor = TEXT})
				clay.Text(
					tr("Share a problem with your group."),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
				)
				clay.Text(tr("Title"), {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
				input_box(
					ui,
					"IssueSubject",
					&ui.issue_subject,
					tr("Issue title"),
					ui.focus == .Issue_Subject,
					0,
				)
				clay.Text(
					tr("Description"),
					{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT},
				)
				issue_editor(
					ui,
					&ui.issue_body,
					.Issue_Body,
					tr("Describe the issue (Markdown)"),
					200,
				)
				clay.Text(tr("Labels"), {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
				input_box(
					ui,
					"IssueLabels",
					&ui.issue_labels,
					tr("Labels, separated by commas"),
					ui.focus == .Issue_Labels,
					0,
				)
			}
			if clay.UI(clay.ID("IssueFormFooter"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					padding = clay.PaddingAll(pad),
					childGap = 12,
					childAlignment = {y = .Center},
				},
				border = {color = DIVIDER, width = {top = 1}},
			},
			) {
				if !narrow {micro_button("IssueBack", "Back to issues")}
				if clay.UI(clay.ID("IssueFormSpace"))(
				{layout = {sizing = {width = clay.SizingGrow()}}},
				) {}
				if ui.issue_ticket ==
				   0 {issue_button("IssueCreate", tr("Create issue"))} else {clay.Text(tr("Sending..."), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})}
			}
		} else if slot, found := ui.issue_index[ui.issue_selected]; found && issue_page != nil {
			row := &ui.issues[slot]
			record := &issue_page.items[row.record]
			if clay.UI(clay.ID("Timeline"))(
			{
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					padding = clay.PaddingAll(pad),
					childGap = 22,
				},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
			},
			) {
				if clay.UI(clay.ID("IssueStatusBar"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						childGap = 8,
						childAlignment = {y = .Center},
					},
				},
				) {
					if clay.UI(clay.ID("IssueStatusBadge"))(
					{
						layout = {padding = {left = 9, right = 9, top = 5, bottom = 5}},
						backgroundColor = SELECTED,
						cornerRadius = rr(5),
					},
					) {
						clay.Text(
							tr(ISSUE_STATUS_NAMES[row.status]),
							{
								fontId = FONT_BODY,
								fontSize = 12,
								textColor = row.status == .Closed ? TEXT_DIM : ACCENT,
							},
						)
					}
					if clay.UI(clay.ID("IssueStatusSpace"))(
					{layout = {sizing = {width = clay.SizingGrow()}}},
					) {}
					if ui.issue_ticket == 0 &&
					   (ui.issue_admin || string(record.sender) == ui.account_ref) {
						for name, i in ([3]string{N_("Reopen"), N_("Resolve"), N_("Close")}) {if Issue_Status(i) != row.status {micro_button(fmt.tprintf("IssueStatus%d", i), tr(name))}}
					}
				}
				if clay.UI(clay.ID("IssueTitle"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						childGap = 14,
						childAlignment = {y = .Center},
					},
				},
				) {
					crop_circle("IssueIdentityDetail", 0, row.id, 44)
					clay.Text(
						issue_tag(record.tags[:record.tags_len], "subject"),
						{fontId = FONT_TITLE, fontSize = 24, textColor = TEXT},
					)
				}
				issue_author(ui, record, 0)
				if clay.UI(clay.ID("IssueDescription"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						layoutDirection = .TopToBottom,
						childGap = 3,
					},
				},
				) {
					if len(ui.issue_blocks) >
					   0 {md_blocks(ui.issue_blocks[:], 0xD1000000, wrap_w = width)} else {body_text(0xD1000000, string(record.plaintext), 14, TEXT, wrap_w = width)}
				}
				// Labels stack so arbitrary user labels also fit a narrow window.
				for tag, i in record.tags[:record.tags_len] {
					if tag.values_len != 2 || string(tag.values[0]) != "t" {continue}
					if clay.UI(clay.ID("IssueLabel", u32(i)))(
					{
						layout = {padding = {left = 8, right = 8, top = 4, bottom = 4}},
						backgroundColor = ROW_BG,
						cornerRadius = rr(4),
					},
					) {clay.Text(string(tag.values[1]), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})}
				}
				if clay.UI(clay.ID("IssueDiscussionHeading"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						padding = {top = 22},
						childGap = 8,
					},
					border = {color = DIVIDER, width = {top = 1}},
				},
				) {
					clay.Text(
						tr("Discussion"),
						{fontId = FONT_TITLE, fontSize = 14, textColor = TEXT},
					)
					clay.Text(
						fmt.tprintf("%d", len(row.comments)),
						{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
					)
				}
				comments := make(map[string]bool, context.temp_allocator)
				for comment in row.comments {comments[comment.id] = true}
				if len(ui.thread_stack) > 0 {thread_bar(ui); thread_root_plate(ui)}
				run: Msg_Run
				wrap_w := body_wrap_w()
				for msg, i in ui.messages {
					if !comments[msg.id] ||
					   (len(ui.thread_stack) > 0 && msg.thread_of != thread_cur(ui)) {continue}
					message_row(u32(i), msg, msg_run_step(&run, msg, wrap_w))
				}
				for p, i in ui.pending {
					if p.group_id == ui.chats[ui.selected].group_id &&
					   p.issue.root == row.id &&
					   (len(ui.thread_stack) == 0 ||
							   p.thread == thread_cur(ui)) {pending_row(u32(i), ui, p)}
				}
			}
			scrollbar(clay.ID("Timeline"))
			chat_composer(ui)
		} else {
			if clay.UI(clay.ID("IssueEmpty"))(
			{
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					padding = clay.PaddingAll(pad),
					childGap = 16,
					childAlignment = {x = .Center, y = .Center},
				},
			},
			) {
				clay.Text(ICON_COMMENTS, {fontId = FONT_ICON, fontSize = 32, textColor = TEXT_LO})
				clay.Text(
					tr("Select an issue"),
					{fontId = FONT_TITLE, fontSize = 22, textColor = TEXT},
				)
				clay.Text(
					tr("Select an issue to read its discussion."),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
				)
			}
		}
	}
}

@(private)
handle_issues :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	if ui.issue_filter_open {
		if rl.IsKeyPressed(.ESCAPE) {ui.issue_filter_open = false; return true}
		if mouse_released() {
			for i in 0 ..< 4 {if clicked(fmt.tprintf("IssueFilter%d", i)) {ui.issue_filter = i}}
			ui.issue_filter_open = false
			return true
		}
	}
	if clicked("IssueFilterToggle") {ui.issue_filter_open = true; return true}
	if clicked("IssueClose") ||
	   (rl.IsKeyPressed(.ESCAPE) && !ui.issue_new && ui.issue_selected == "") {
		ui.issues_open = false; ui.focus = .Compose; issues_sync_route(ui, client); return true
	}
	if clicked("IssueBack") ||
	   (rl.IsKeyPressed(.ESCAPE) &&
			   (ui.issue_new ||
					   (len(ui.compose) == 0 && ui.editing == "" && len(ui.thread_stack) == 0))) {
		ui.issue_new = false
		issues_select(ui, client, "")
		ui.focus = .Issue_Search
		return true
	}
	if ui.issue_ticket != 0 && ui.issue_new {return true}
	if ui.issue_new {
		compose_mouse(ui, &ui.issue_body, .Issue_Body)
		fields := [3]^[dynamic]u8{&ui.issue_subject, &ui.issue_body, &ui.issue_labels}
		ids := [3]string{"IssueSubject", "IssueBody", "IssueLabels"}
		focuses := [3]Focus{.Issue_Subject, .Issue_Body, .Issue_Labels}
		for buf, i in fields {if field_mouse(ui, buf, ids[i], 14) {ui.focus = focuses[i]}}
		for buf, i in fields {if ui.focus == focuses[i] {edit_text(ui, buf, buf == &ui.issue_body)}}
		if ui.focus == .Issue_Body &&
		   rl.IsKeyPressed(.ENTER) &&
		   !ctrl_down() {ed_insert(ui, &ui.issue_body, "\n")}
		if rl.IsKeyPressed(
			.TAB,
		) {ui.focus = ui.focus == .Issue_Subject ? .Issue_Body : ui.focus == .Issue_Body ? .Issue_Labels : .Issue_Subject}
	}
	if field_mouse(ui, &ui.issue_search, "IssueSearch", 14) {ui.focus = .Issue_Search}
	if ui.focus == .Issue_Search &&
	   (ui.issue_new || ui.issue_selected == "") {edit_text(ui, &ui.issue_search)}
	if clicked(
		"IssueNew",
	) {ui.issue_new = true; ui.focus = .Issue_Subject; issues_sync_route(ui, client); return true}
	if mouse_released() {
		for row, i in ui.issues {
			if clay.PointerOver(clay.ID("IssueRow", u32(i))) {
				ui.issue_new = false
				issues_select(ui, client, string(issue_page.items[row.record].message_id_hex))
				ui.focus = .Compose
				return true
			}
		}
	}
	if ui.issue_ticket != 0 ||
	   ui.issue_setting != .Enabled ||
	   ui.chats[ui.selected].pending {return true}
	if ui.issue_new && (clicked("IssueCreate") || (ctrl_down() && rl.IsKeyPressed(.ENTER))) {
		subject := strings.trim_space(string(ui.issue_subject[:]))
		body := strings.trim_space(string(ui.issue_body[:]))
		if subject == "" ||
		   body ==
			   "" {ui.client_status = strings.clone(tr("Enter an issue title and description.")); return true}
		tags := make([dynamic][]string, context.temp_allocator)
		append(&tags, []string{"subject", subject})
		for label in strings.split(string(ui.issue_labels[:]), ",", context.temp_allocator) {
			clean := strings.trim_space(label)
			if clean != "" {append(&tags, []string{"t", clean})}
		}
		ui.issue_action = .Create
		ui.issue_ticket = spawn_custom(ui, client, 1621, tags[:], body, .Issue)
		return true
	}
	slot, found := ui.issue_index[ui.issue_selected]
	if !found || issue_page == nil {return true}
	root := &issue_page.items[ui.issues[slot].record]
	id, author := string(root.message_id_hex), string(root.sender)
	if author != ui.account_ref && !ui.issue_admin {return ui.issue_new}
	for _, i in ISSUE_STATUS_NAMES {
		if !clicked(fmt.tprintf("IssueStatus%d", i)) {continue}
		ui.issue_action = .Status
		ui.issue_ticket = spawn_custom(
			ui,
			client,
			1630 + u64(i),
			[][]string{{"e", id, "", "root"}, {"p", author}},
			"",
			.Issue,
		)
	}
	return ui.issue_new
}

@(private)
issues_complete :: proc(ui: ^Ui_State, done: Op_Done) {
	defer {delete(done.account); delete(done.group); delete(done.target); delete(done.content)
		delete(done.err)}
	issues_refresh()
	if ui.selected < 0 ||
	   done.account != ui.account_ref ||
	   done.group != ui.chats[ui.selected].group_id ||
	   done.ticket != ui.issue_ticket {return}
	ui.issue_ticket = 0
	if done.err !=
	   "" {ui.client_status = strings.clone(tr("Couldn't update issues. Please try again.")); return}
	switch ui.issue_action {
	case .Create:
		clear(&ui.issue_subject); clear(&ui.issue_body); clear(&ui.issue_labels)
		ui.issue_new = false
	case .Setting, .Status:
	}
}
