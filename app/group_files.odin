package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
Group_File_Type :: enum {
	All,
	Images,
	Videos,
	Audio,
	Documents,
	Archives,
	Models,
	Fonts,
	Apps,
	Other,
}
@(private)
GROUP_FILE_TYPES := [Group_File_Type]string {
	.All       = N_("All types"),
	.Images    = N_("Images"),
	.Videos    = N_("Videos"),
	.Audio     = N_("Audio"),
	.Documents = N_("Documents"),
	.Archives  = N_("Archives"),
	.Models    = N_("3D models"),
	.Fonts     = N_("Fonts"),
	.Apps      = N_("Apps"),
	.Other     = N_("Other files"),
}
@(private)
GROUP_FILE_ICONS := [Group_File_Type]string {
	.All       = ICON_FOLDER,
	.Images    = "\uf03e",
	.Videos    = "\uf03d",
	.Audio     = "\uf001",
	.Documents = "\uf15c",
	.Archives  = ICON_ARCHIVE,
	.Models    = "\uf1b2",
	.Fonts     = "\uf031",
	.Apps      = ICON_CODE,
	.Other     = ICON_CLIP,
}
@(private)
Group_File_Menu :: enum {
	None,
	Type,
	Sender,
}
@(private)
GROUP_FILE_CARD_H :: 196
@(private)
GROUP_FILE_GAP :: 12
@(private)
GROUP_FILE_OPTION_H :: 32

@(private)
Group_File :: struct {
	record: ^marmot.Timeline_Message_Record,
	index:  int,
	kind:   Group_File_Type,
}
@(private)
Group_Files_Job :: struct {
	worker:         ^thread.Thread,
	client:         ^marmot.Client,
	account, group: cstring,
	cancel:         bool, // atomic; checked between history pages
	pages:          [dynamic]^marmot.Timeline_Page, // owns records referenced by files
	files:          [dynamic]Group_File,
	senders:        [dynamic]string, // borrowed from pages; includes former members
	err:            string,
}
@(private)
group_files_job: ^Group_Files_Job

@(private)
group_file_type :: proc(name, media_type: string) -> Group_File_Type {
	mime := media_type
	if mime == "" || mime == "application/octet-stream" {mime = media_type_for(name)}
	switch media_kind(name, mime) {
	case .Image, .Sticker, .Loop, .Emoji:
		return .Images
	case .Video:
		return .Videos
	case .Audio:
		return .Audio
	case .Pdf, .Text, .Code:
		return .Documents
	case .Arc:
		return .Archives
	case .Mesh, .Gcode:
		return .Models
	case .Font:
		return .Fonts
	case .Xdc:
		return .Apps
	case .File, .Torrent:
		if strings.has_prefix(mime, "text/") ||
		   strings.contains(mime, "officedocument") ||
		   strings.contains(mime, "opendocument") ||
		   mime == "application/msword" ||
		   mime == "application/vnd.ms-excel" ||
		   mime == "application/vnd.ms-powerpoint" {return .Documents}
		return .Other
	}
	return .Other
}

@(private)
group_files_collect :: proc(job: ^Group_Files_Job, page: ^marmot.Timeline_Page) {
	for i := int(page.messages_len) - 1; i >= 0; i -= 1 {
		record := &page.messages[i]
		if record.deleted ||
		   record.invalidation_status != nil ||
		   record.kind == 5 ||
		   record.kind == 1009 {continue}
		for &outcome, index in record.media[:record.media_len] {
			if outcome.tag != .ACCEPTED {continue}
			ref := &outcome.body.accepted.reference
			append(
				&job.files,
				Group_File {
					record,
					index,
					group_file_type(string(ref.file_name), string(ref.media_type)),
				},
			)
		}
	}
}

@(private)
group_files_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	job := (^Group_Files_Job)(t.data)
	defer frame_wake()
	defer free_all(context.temp_allocator)
	query := marmot.Timeline_Message_Query {
		group_id_hex = job.group,
		has_limit    = true,
		limit        = TL_PAGE,
	}
	defer delete(query.before_message_id)
	seen := make(map[string]bool)
	defer delete(seen)
	// ponytail: the C API has no attachment query. Scan history and retain
	// only pages with attachments; replace with an attachment query when available.
	for !sync.atomic_load(&job.cancel) {
		page: ^marmot.Timeline_Page
		if marmot.timeline_messages(job.client, job.account, &query, &page) != .OK {
			job.err = strings.clone("Couldn't load files. Please try again.")
			return
		}
		before := len(job.files)
		group_files_collect(job, page)
		for file in job.files[before:] {
			sender := string(file.record.sender)
			if !seen[sender] {seen[sender] = true; append(&job.senders, sender)}
		}
		more := page.has_more_before && page.messages_len > 0
		if more {
			delete(query.before_message_id)
			query.has_before, query.before = true, page.messages[0].timeline_at
			query.before_message_id = strings.clone_to_cstring(
				string(page.messages[0].message_id_hex),
			)
		}
		if len(job.files) >
		   before {append(&job.pages, page)} else {marmot.timeline_page_free(page)}
		free_all(context.temp_allocator)
		if !more {return}
	}
}

@(private)
group_files_stop :: proc() {
	job := group_files_job
	if job == nil {return}
	sync.atomic_store(&job.cancel, true)
	if job.worker != nil {thread.join(job.worker); thread.destroy(job.worker)}
	for page in job.pages {marmot.timeline_page_free(page)}
	delete(job.pages); delete(job.files); delete(job.senders)
	delete(job.account); delete(job.group); delete(job.err)
	free(job)
	group_files_job = nil
}

@(private)
group_files_tick :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	open :=
		ui.page == .Chats && ui.group_files_open && ui.selected >= 0 && ui.selected < len(ui.chats)
	job := group_files_job
	if job != nil {
		if !open ||
		   string(job.account) != ui.account_ref ||
		   string(job.group) != ui.chats[ui.selected].group_id {
			sync.atomic_store(&job.cancel, true)
			ui.group_files_sender, ui.group_files_menu = "", .None
		}
		if job.worker != nil && thread.is_done(job.worker) {
			thread.join(job.worker); thread.destroy(job.worker); job.worker = nil
			if !sync.atomic_load(&job.cancel) {
				for sender in job.senders {profile_info(client, sender)}
			}
		}
		if sync.atomic_load(&job.cancel) {
			ui.group_files_sender, ui.group_files_menu = "", .None
			if !open {ui.group_files_open = false}
			if job.worker != nil {return}
			group_files_stop()
		} else {return}
	}
	if !open {ui.group_files_open = false; return}
	if client == nil {return}
	job = new(Group_Files_Job)
	job.client = client
	job.account = strings.clone_to_cstring(ui.account_ref)
	job.group = strings.clone_to_cstring(ui.chats[ui.selected].group_id)
	job.worker = thread.create(group_files_worker)
	job.worker.data = job
	group_files_job = job
	thread.start(job.worker)
}

@(private)
group_file_matches :: proc(ui: ^Ui_State, file: Group_File) -> bool {
	record := file.record
	if ui.hidden[string(record.message_id_hex)] {return false}
	if record.has_retention_expires_at &&
	   record.retention_expires_at <= u64(time.now()._nsec / 1_000_000_000) {return false}
	return(
		(ui.group_files_type == .All || ui.group_files_type == file.kind) &&
		(ui.group_files_sender == "" || ui.group_files_sender == string(record.sender)) \
	)
}

@(private)
group_sender_label :: proc(ui: ^Ui_State, id: string) -> string {
	if id == "" {return tr("All senders")}
	if id == ui.account_ref {return tr("You")}
	if nick := ui.nicknames[id]; nick != "" {return nick}
	return profile_label(nil, id)
}

@(private)
group_files_panel :: proc(ui: ^Ui_State) {
	job := group_files_job
	ready := job != nil && job.worker == nil && !sync.atomic_load(&job.cancel)
	matches := make([dynamic]int, context.temp_allocator)
	if ready {for file, i in job.files {if group_file_matches(ui, file) {append(&matches, i)}}}
	if clay.UI(clay.ID("GroupFilesPanel"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(18),
			childGap = 16,
		},
		backgroundColor = BG,
	},
	) {
		if clay.UI(clay.ID("GroupFilesHead"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 10,
				childAlignment = {y = .Center},
			},
		},
		) {
			clay.Text(tr("Files"), {fontId = FONT_TITLE, fontSize = 22, textColor = TEXT})
			if ready {
				if clay.UI(clay.ID("GroupFilesCount"))(
				{
					layout = {padding = {left = 8, right = 8, top = 3, bottom = 3}},
					backgroundColor = ROW_BG,
					cornerRadius = rr(10),
				},
				) {
					clay.Text(
						fmt.tprintf("%d", len(matches)),
						{fontId = FONT_MONO, fontSize = 11, textColor = TEXT_DIM},
					)
				}
			}
			if clay.UI(clay.ID("GroupFilesGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			if clay.UI(clay.ID("GroupFilesRefresh"))(
			{
				layout = {padding = clay.PaddingAll(8)},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(6),
			},
			) {
				clay.Text(tr("Refresh"), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
			}
			if clay.UI(clay.ID("GroupFilesBack"))(
			{
				layout = {padding = clay.PaddingAll(8)},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(6),
			},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 14, textColor = TEXT_DIM})
				if hovered() {tooltip("Back to chat")}
			}
		}
		if !ready {
			clay.Text(tr("Loading…"), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
			return
		}
		if job.err != "" {
			clay.Text(
				tr("Couldn't load files. Please try again."),
				{fontId = FONT_BODY, fontSize = 13, textColor = DANGER},
			)
			return
		}
		if clay.UI(clay.ID("GroupFilesFilters"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}},
		) {
			for menu in ([]Group_File_Menu{.Type, .Sender}) {
				active := menu == .Type ? ui.group_files_type != .All : ui.group_files_sender != ""
				if clay.UI(clay.ID("GroupFilesFilter", u32(menu)))(
				{
					layout = {
						sizing = {width = clay.SizingFit({max = max(100, (page_w(ui) - 48) / 2)})},
						padding = {left = 12, right = 12, top = 8, bottom = 8},
						childGap = 8,
						childAlignment = {y = .Center},
					},
					backgroundColor = active ? SELECTED : hovered() ? HOVER : ROW_BG,
					cornerRadius = rr(8),
					border = {color = active ? ACCENT : CARD_BORDER, width = bw()},
				},
				) {
					clay.Text(
						menu == .Type ? ICON_FOLDER : ICON_PROFILE,
						{
							fontId = FONT_ICON,
							fontSize = 11,
							textColor = active ? ACCENT : TEXT_DIM,
						},
					)
					if clay.UI(clay.ID("GroupFilterLabel", u32(menu)))(
					{clip = {horizontal = true}},
					) {
						clay.Text(
							menu == .Type ? tr(GROUP_FILE_TYPES[ui.group_files_type]) : group_sender_label(ui, ui.group_files_sender),
							{
								fontId = FONT_BODY,
								fontSize = 12,
								textColor = TEXT,
								wrapMode = .None,
							},
						)
					}
					clay.Text("⌄", {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
				}
			}
		}
		if ui.group_files_menu != .None {
			menu := ui.group_files_menu
			count := menu == .Type ? len(GROUP_FILE_TYPES) : len(job.senders) + 1
			if clay.UI(clay.ID("GroupFilesOptions"))(
			{
				layout = {
					sizing = {
						width = clay.SizingFixed(min(260, page_w(ui) - 40)),
						height = clay.SizingFixed(f32(min(count, 7) * GROUP_FILE_OPTION_H)),
					},
					layoutDirection = .TopToBottom,
				},
				backgroundColor = CARD,
				border = {color = CARD_BORDER, width = bw()},
				cornerRadius = rr(8),
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
				floating = {
					attachTo = .ElementWithId,
					parentId = clay.ID("GroupFilesFilters").id,
					zIndex = 9,
					offset = {0, 6},
					attachment = {element = .LeftTop, parent = .LeftBottom},
				},
			},
			) {
				data := clay.GetScrollContainerData(clay.ID("GroupFilesOptions"))
				first :=
					data.found ? clamp(int(-data.scrollPosition.y / GROUP_FILE_OPTION_H), 0, count) : 0
				last := min(first + 9, count)
				if clay.UI(clay.ID("GroupOptionsBefore"))(
				{
					layout = {
						sizing = {height = clay.SizingFixed(f32(first * GROUP_FILE_OPTION_H))},
					},
				},
				) {}
				for i in first ..< last {
					label :=
						menu == .Type ? tr(GROUP_FILE_TYPES[Group_File_Type(i)]) : group_sender_label(ui, i == 0 ? "" : job.senders[i - 1])
					selected :=
						menu == .Type ? int(ui.group_files_type) == i : ui.group_files_sender == (i == 0 ? "" : job.senders[i - 1])
					if clay.UI(clay.ID("GroupFilesOption", u32(i)))(
					{
						layout = {
							sizing = {
								width = clay.SizingGrow(),
								height = clay.SizingFixed(GROUP_FILE_OPTION_H),
							},
							padding = {left = 12, right = 12},
							childGap = 8,
							childAlignment = {y = .Center},
						},
						backgroundColor = hovered() || ui.group_files_option == i ? HOVER : {},
						clip = {horizontal = true},
					},
					) {
						clay.Text(
							selected ? ICON_CHECK : " ",
							{fontId = FONT_ICON, fontSize = 10, textColor = ACCENT},
						)
						clay.Text(
							label,
							{
								fontId = FONT_BODY,
								fontSize = 13,
								textColor = TEXT,
								wrapMode = .None,
							},
						)
					}
				}
				if clay.UI(clay.ID("GroupOptionsAfter"))(
				{
					layout = {
						sizing = {
							height = clay.SizingFixed(f32((count - last) * GROUP_FILE_OPTION_H)),
						},
					},
				},
				) {}
			}
			scrollbar(clay.ID("GroupFilesOptions"), 10)
		}
		if len(matches) == 0 {
			clay.Text(
				tr("No files match these filters."),
				{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
			)
		}
		if clay.UI(clay.ID("GroupFilesList"))(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				layoutDirection = .TopToBottom,
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			width := max(120, page_w(ui) - 36)
			columns := max(1, int((width + GROUP_FILE_GAP) / 160))
			cell := (width - f32((columns - 1) * GROUP_FILE_GAP)) / f32(columns)
			rows := (len(matches) + columns - 1) / columns
			stride := GROUP_FILE_CARD_H + GROUP_FILE_GAP
			data := clay.GetScrollContainerData(clay.ID("GroupFilesList"))
			first := data.found ? clamp(int(-data.scrollPosition.y / f32(stride)) - 1, 0, rows) : 0
			last := min(rows, first + int(f32(rl.GetScreenHeight()) / UI_ZOOM / f32(stride)) + 3)
			if clay.UI(clay.ID("GroupFilesBefore"))(
			{layout = {sizing = {height = clay.SizingFixed(f32(first * stride))}}},
			) {}
			for row in first ..< last {
				if clay.UI(clay.ID("GroupFileRow", u32(row)))(
				{
					layout = {
						sizing = {
							width = clay.SizingGrow(),
							height = clay.SizingFixed(f32(stride)),
						},
						childGap = GROUP_FILE_GAP,
					},
				},
				) {
					for i in matches[row * columns:min((row + 1) * columns, len(matches))] {
						group_file_card(ui, job, i, cell)
					}
				}
			}
			if clay.UI(clay.ID("GroupFilesAfter"))(
			{layout = {sizing = {height = clay.SizingFixed(f32((rows - last) * stride))}}},
			) {}
		}
		scrollbar(clay.ID("GroupFilesList"))
	}
}

@(private)
group_file_card :: proc(ui: ^Ui_State, job: ^Group_Files_Job, index: int, width: f32) {
	file := job.files[index]
	ref := media_reference(file.record, file.index)
	name := string(ref.file_name)
	if name == "" {name = tr("Attachment")}
	key := string(ref.plaintext_sha256)
	tex: ^rl.Texture2D
	if file.kind == .Images {
		cached: bool
		tex, cached = media_textures[key]
		if !cached &&
		   job.client != nil {media_enqueue(job.client, job.account, job.group, ref, .Image, key)}
	}
	if clay.UI(clay.ID("GroupFile", u32(index)))(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(width),
				height = clay.SizingFixed(GROUP_FILE_CARD_H),
			},
			layoutDirection = .TopToBottom,
		},
		backgroundColor = hovered() ? HOVER : CARD,
		border = {color = hovered() ? ACCENT : CARD_BORDER, width = bw()},
		cornerRadius = rr(10),
	},
	) {
		if hovered() {tooltip(name)}
		if clay.UI(clay.ID("GroupFilePreview", u32(index)))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(120)},
				layoutDirection = .TopToBottom,
				childGap = 8,
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = ROW_BG,
			cornerRadius = {topLeft = 10 * R_SCALE, topRight = 10 * R_SCALE},
		},
		) {
			if tex != nil {
				scale := min((width - 2) / f32(tex.width), f32(118) / f32(tex.height))
				if clay.UI(clay.ID("GroupFileImage", u32(index)))(
				{
					layout = {
						sizing = {
							clay.SizingFixed(f32(tex.width) * scale),
							clay.SizingFixed(f32(tex.height) * scale),
						},
					},
					image = {imageData = tex},
				},
				) {}
			} else {
				clay.Text(
					GROUP_FILE_ICONS[file.kind],
					{fontId = FONT_ICON, fontSize = 26, textColor = ACCENT},
				)
				clay.Text(
					tr(GROUP_FILE_TYPES[file.kind]),
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
				)
			}
		}
		if clay.UI(clay.ID("GroupFileInfo", u32(index)))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				padding = clay.PaddingAll(10),
				childGap = 8,
			},
		},
		) {
			if clay.UI(clay.ID("GroupFileName", u32(index)))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {
				clay.Text(
					group_file_label(name, width - 20, FONT_TITLE, 12),
					{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT, wrapMode = .None},
				)
			}
			if clay.UI(clay.ID("GroupFileMeta", u32(index)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					childGap = 6,
					childAlignment = {y = .Center},
				},
			},
			) {
				if clay.UI(clay.ID("GroupFileByline", u32(index)))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						layoutDirection = .TopToBottom,
						childGap = 2,
					},
				},
				) {
					clay.Text(
						group_file_label(
							group_sender_label(ui, string(file.record.sender)),
							width - 50,
							FONT_BODY,
							11,
						),
						{
							fontId = FONT_BODY,
							fontSize = 11,
							textColor = TEXT_DIM,
							wrapMode = .None,
						},
					)
					date: string
					{context.allocator = context.temp_allocator
						date = format_day(file.record.timeline_at)}
					clay.Text(
						date,
						{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO, wrapMode = .None},
					)
				}
				if clay.UI(clay.ID("GroupFileSave", u32(index)))(
				{
					layout = {padding = clay.PaddingAll(6)},
					backgroundColor = hovered() ? SELECTED : {},
					cornerRadius = rr(6),
				},
				) {
					clay.Text(
						ICON_DOWNLOAD,
						{fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM},
					)
					if hovered() {tooltip("Save attachment")}
				}
			}
		}
	}
}

// Fit whole UTF-8 characters without allocating a scroll container per label.
@(private)
group_file_label :: proc(text: string, width: f32, font, size: u16) -> string {
	if rl.MeasureTextLine(font, size, text, 0).x <= width {return text}
	available := max(0, width - rl.MeasureTextLine(font, size, "…", 0).x)
	lo, hi := 0, len(text)
	for lo < hi {
		mid := (lo + hi + 1) / 2
		cut := mid
		for cut < len(text) && (u8(text[cut]) & 0xc0) == 0x80 {cut += 1}
		if rl.MeasureTextLine(font, size, text[:cut], 0).x <=
		   available {lo = cut} else {hi = mid - 1}
	}
	return fmt.tprintf("%s…", text[:lo])
}

@(private)
handle_group_files :: proc(ui: ^Ui_State) {
	if rl.IsKeyPressed(.ESCAPE) || clicked("GroupFilesBack") {
		if ui.group_files_menu !=
		   .None {ui.group_files_menu = .None} else {ui.group_files_open = false}
		return
	}
	job := group_files_job
	if job == nil || job.worker != nil {return}
	if clicked("GroupFilesRefresh") {sync.atomic_store(&job.cancel, true); return}
	if job.err != "" {return}
	if rl.IsKeyPressed(.TAB) {
		ui.group_files_menu = ui.group_files_menu == .Type ? .Sender : .Type
		ui.group_files_option = 0
		if data := clay.GetScrollContainerData(clay.ID("GroupFilesOptions"));
		   data.found {data.scrollPosition.y = 0}
		return
	}
	for menu in ([]Group_File_Menu{.Type, .Sender}) {
		if mouse_released() && clay.PointerOver(clay.ID("GroupFilesFilter", u32(menu))) {
			ui.group_files_menu = ui.group_files_menu == menu ? .None : menu
			ui.group_files_option = 0
			if data := clay.GetScrollContainerData(clay.ID("GroupFilesOptions"));
			   data.found {data.scrollPosition.y = 0}
			return
		}
	}
	if ui.group_files_menu != .None {
		count := ui.group_files_menu == .Type ? len(GROUP_FILE_TYPES) : len(job.senders) + 1
		step := rl.IsKeyPressed(.DOWN) ? 1 : rl.IsKeyPressed(.UP) ? -1 : 0
		ui.group_files_option = clamp(ui.group_files_option + step, 0, count - 1)
		if step != 0 {
			if data := clay.GetScrollContainerData(clay.ID("GroupFilesOptions")); data.found {
				data.scrollPosition.y = -f32(
					max(0, ui.group_files_option - 4) * GROUP_FILE_OPTION_H,
				)
			}
		}
		for i in 0 ..< count {
			if !(mouse_released() && clay.PointerOver(clay.ID("GroupFilesOption", u32(i)))) &&
			   !(rl.IsKeyPressed(.ENTER) && ui.group_files_option == i) {continue}
			if ui.group_files_menu ==
			   .Type {ui.group_files_type = Group_File_Type(i)} else {ui.group_files_sender = i == 0 ? "" : job.senders[i - 1]}
			ui.group_files_menu = .None
			if data := clay.GetScrollContainerData(clay.ID("GroupFilesList"));
			   data.found {data.scrollPosition.y = 0}
			return
		}
		if mouse_released() {ui.group_files_menu = .None}
		return
	}
	if !mouse_released() {return}
	for file, i in job.files {
		if !group_file_matches(ui, file) ||
		   !clay.PointerOver(clay.ID("GroupFile", u32(i))) {continue}
		ref := media_reference(file.record, file.index)
		name := string(ref.file_name)
		if name == "" {name = tr("Attachment")}
		if file.kind == .Images && !clay.PointerOver(clay.ID("GroupFileSave", u32(i))) {
			key := string(ref.plaintext_sha256)
			tex, cached := media_textures[key]
			if tex == nil {
				if cached {old, _ := delete_key(&media_textures, key); delete(old)}
				return
			}
			preview_close()
			preview.kind = .Slides
			append(
				&preview.slides,
				Slide {
					strings.clone(string(file.record.message_id_hex)),
					strings.clone(name),
					file.index,
					tex,
				},
			)
			preview_shown = true
			return
		}
		start_att_save(
			{
				group = string(job.group),
				msg_id = string(file.record.message_id_hex),
				index = file.index,
				name = name,
			},
		)
		return
	}
}
