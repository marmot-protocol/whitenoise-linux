package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:text/edit"
import "core:time"

import marmot "../marmot"
import "nendo"
import rl "sdlrl"

foreign import timestamp_lib {WN_BUILD_DIR + "/libwntimestamp.a"}

@(private = "file", default_calling_convention = "c")
foreign timestamp_lib {
	wn_timestamp_local :: proc(seconds: i64, out: ^Local_Time) -> c.int ---
	wn_timestamp_unix :: proc(local: ^Local_Time, out: ^i64) -> c.int ---
}

@(private)
TIMESTAMP_ICON :: "\uf017"

@(private)
timestamp_token :: proc(seconds: i64, style: marmot.Markdown_Timestamp_Style) -> string {
	codes := [9]u8{'t', 'T', 'd', 'D', 'f', 'F', 's', 'S', 'R'}
	index := int(style)
	code := index >= 0 && index < len(codes) ? codes[index] : u8('f')
	return fmt.tprintf("<t:%d:%c>", seconds, code)
}

@(private = "file")
timestamp_relative :: proc(seconds, now: i64) -> string {
	// Flipping the sign bit orders signed instants in u64. Subtract in
	// descending order so even the distance between i64 extremes fits.
	at := transmute(u64)seconds ~ (u64(1) << 63)
	current := transmute(u64)now ~ (u64(1) << 63)
	future := at > current
	distance := future ? at - current : current - at
	units := [?]struct {
		seconds:                                      u64,
		past_one, past_many, future_one, future_many: string,
	} {
		{31536000, N_("%d year ago"), N_("%d years ago"), N_("in %d year"), N_("in %d years")},
		{2592000, N_("%d month ago"), N_("%d months ago"), N_("in %d month"), N_("in %d months")},
		{86400, N_("%d day ago"), N_("%d days ago"), N_("in %d day"), N_("in %d days")},
		{3600, N_("%d hour ago"), N_("%d hours ago"), N_("in %d hour"), N_("in %d hours")},
		{60, N_("%d minute ago"), N_("%d minutes ago"), N_("in %d minute"), N_("in %d minutes")},
		{1, N_("%d second ago"), N_("%d seconds ago"), N_("in %d second"), N_("in %d seconds")},
	}
	index := len(units) - 1
	for unit, i in units {
		if distance >= unit.seconds {
			index = i
			break
		}
	}
	unit := units[index]
	count := distance / unit.seconds
	pattern := count == 1 ? unit.past_one : unit.past_many
	if future {pattern = count == 1 ? unit.future_one : unit.future_many}
	return fmt.tprintf(tr(pattern), count)
}

// Resolve at display time: relative labels use the current clock, the
// native lookup re-reads the device's timezone each call, and absolute
// labels follow the Date format and Time format settings:
//
//   t    2:30 PM        f s  Oct 6, 2026 · 2:30 PM
//   T    2:30:00 PM     S    Oct 6, 2026 · 2:30:00 PM
//   d D  Oct 6, 2026    F    Tuesday, Oct 6, 2026 · 2:30 PM
@(private)
timestamp_label :: proc(seconds: i64, style: marmot.Markdown_Timestamp_Style, now: i64) -> string {
	if style == .RELATIVE {return timestamp_relative(seconds, now)}
	local: Local_Time
	if wn_timestamp_local(seconds, &local) == 0 {return timestamp_token(seconds, style)}
	return timestamp_absolute(local, style)
}

@(private = "file")
timestamp_absolute :: proc(local: Local_Time, style: marmot.Markdown_Timestamp_Style) -> string {
	context.allocator = context.temp_allocator
	#partial switch style {
	case .SHORT_TIME:
		return clock_text(local, .Omit)
	case .LONG_TIME:
		return clock_text(local, .Show)
	case .SHORT_DATE, .LONG_DATE:
		return date_text(local, .Show)
	case .SHORT_DATE_TIME, .COMPACT_DATE_TIME:
		return date_clock_text(local, .Omit)
	case .COMPACT_DATE_TIME_SECONDS:
		return date_clock_text(local, .Show)
	case .LONG_DATE_TIME:
		return fmt.aprintf(
			"%s, %s",
			tr(WEEKDAY_NAMES[local.weekday]),
			date_clock_text(local, .Omit),
		)
	}
	return ""
}

@(private)
Timestamp_Editor :: struct {
	open:      bool,
	style:     marmot.Markdown_Timestamp_Style,
	input:     [dynamic]u8,
	selection: [2]int,
}

@(private = "file")
TIMESTAMP_STYLES := [?]struct {
	style: marmot.Markdown_Timestamp_Style,
	label: string,
} {
	{.SHORT_TIME, N_("Time only")},
	{.LONG_TIME, N_("Time with seconds")},
	{.SHORT_DATE, N_("Date only")},
	{.SHORT_DATE_TIME, N_("Date and time")},
	{.LONG_DATE_TIME, N_("Full date and time")},
	{.COMPACT_DATE_TIME_SECONDS, N_("Date and time with seconds")},
	{.RELATIVE, N_("Relative time")},
}

@(private)
timestamp_picker_open :: proc(ui: ^Ui_State) {
	if ui.poll_open {return}
	local: Local_Time
	if wn_timestamp_local(time.time_to_unix(time.now()), &local) == 0 {
		toast(ui, tr("Couldn't read your local time. Check your device's clock and try again."))
		return
	}
	picker := &ui.timestamp
	picker.open = true
	picker.style = .SHORT_DATE_TIME
	lo, hi, head := field_sel(ui, &ui.compose)
	picker.selection = {head, head == lo ? hi : lo}
	ed_set(
		ui,
		&picker.input,
		fmt.tprintf(
			"%04d-%02d-%02d %02d:%02d:%02d",
			local.year,
			local.month,
			local.day,
			local.hour,
			local.minute,
			local.second,
		),
	)
	touch_field = {}
	ui.focus = tap_size() ? .Compose : .Timestamp
	if ui.focus == .Timestamp {
		ed_begin(ui, &picker.input)
		ui.ed.selection = {len(picker.input), 0}
		ed_end(ui, &picker.input)
	}
}

@(private = "file")
timestamp_parse_input :: proc(text: string) -> (seconds: i64, valid: bool) {
	text := strings.trim_space(text)
	if len(text) != 16 && len(text) != 19 {return}
	if text[4] != '-' ||
	   text[7] != '-' ||
	   text[10] != ' ' ||
	   text[13] != ':' ||
	   (len(text) == 19 && text[16] != ':') {return}
	local: Local_Time
	fields := [6]^i32 {
		&local.year,
		&local.month,
		&local.day,
		&local.hour,
		&local.minute,
		&local.second,
	}
	for span, i in ([6][2]int{{0, 4}, {5, 7}, {8, 10}, {11, 13}, {14, 16}, {17, 19}}) {
		if span[1] > len(text) {break}
		for digit in transmute([]u8)text[span[0]:span[1]] {
			if digit < '0' || digit > '9' {return}
			fields[i]^ = fields[i]^ * 10 + i32(digit - '0')
		}
	}
	valid = wn_timestamp_unix(&local, &seconds) != 0
	return
}

@(private)
timestamp_picker :: proc(ui: ^Ui_State) {
	picker := &ui.timestamp
	seconds, valid := timestamp_parse_input(string(picker.input[:]))
	id := nendo.id("TimestampModal")
	if nendo.box(id)(
	{
		width = nendo.fixed(modal_w(id, 400)),
		height = nendo.fit(max = modal_h(560)),
		direction = .Column,
		padding = nendo.pad(16),
		gap = 6,
		clip = {y = true, scroll = true},
		color = CARD,
		radius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
		floating = {
			attach_to = .Root,
			z = 11,
			attach = {element = .Center_Center, parent = .Center_Center},
		},
	},
	) {
		nendo.text(tr("Insert timestamp"), {font = FONT_TITLE, size = 18, color = TEXT})
		nendo.text(
			tr("Local date and time (YYYY-MM-DD HH:MM[:SS])."),
			{font = FONT_BODY, size = 12, color = TEXT_DIM},
		)
		gs_field(ui, "TimestampInput", &picker.input, "YYYY-MM-DD HH:MM", .Timestamp)
		for option, i in TIMESTAMP_STYLES {
			settings_option(
				"TimestampStyle",
				u32(i),
				tr(option.label),
				picker.style == option.style,
			)
		}
		now := time.time_to_unix(time.now())
		label :=
			valid ? timestamp_label(seconds, picker.style, now) : tr("Enter a valid date and time in your timezone.")
		nendo.text(label, {font = FONT_TITLE, size = 14, color = valid ? TEXT : DANGER})
		if nendo.box()({width = nendo.grow(), gap = 8}) {
			login_big_button("TimestampCancel", tr("Cancel"), false)
			login_big_button("TimestampInsert", tr("Insert"), true, valid ? .Enabled : .Disabled)
		}
	}
	scrollbar(id, 12)
}

@(private)
handle_timestamp_picker :: proc(ui: ^Ui_State) {
	picker := &ui.timestamp
	if field_mouse(ui, &picker.input, "TimestampInput") {ui.focus = .Timestamp}
	if ui.focus == .Timestamp {edit_text(ui, &picker.input)}
	for option, i in TIMESTAMP_STYLES {
		if clicked_indexed("TimestampStyle", u32(i)) {
			picker.style = option.style
			return
		}
	}
	cancel := rl.IsKeyPressed(.ESCAPE) || clicked("TimestampCancel")
	insert := clicked("TimestampInsert") || (rl.IsKeyPressed(.ENTER) && len(rl.Preedit()) == 0)
	if !cancel && !insert {return}
	seconds: i64
	if !cancel {
		valid: bool
		seconds, valid = timestamp_parse_input(string(picker.input[:]))
		if !valid {return}
	}
	picker.open = false
	touch_field = {}
	ui.focus = .Compose
	ed_begin(ui, &ui.compose)
	ui.ed.selection = picker.selection
	if !cancel {edit.input_text(&ui.ed, timestamp_token(seconds, picker.style))}
	ed_end(ui, &ui.compose)
}

@(private)
standalone_timestamp :: proc(
	body: string,
	blocks: []Md_Block_Ui,
) -> (
	stamp: ^Md_Timestamp,
	paired: bool,
) {
	if len(blocks) != 1 {return}
	block := &blocks[0]
	stamps := block.timestamps[:]
	if block.kind != .Para || len(stamps) == 0 || len(stamps) > 2 || stamps[0].start != 0 {return}
	// Markdown normalizes tokens and removes escapes. Match the plain source too.
	body := strings.trim_space(body)
	if !strings.has_prefix(body, "<t:") {return}
	end := strings.index_byte(body, '>')
	if end < 0 {return}
	first := &stamps[0]
	if len(stamps) == 1 {
		if first.end == len(block.text) && end == len(body) - 1 {return first, false}
		return
	}

	second := &stamps[1]
	if first.style == .RELATIVE ||
	   second.style != .RELATIVE ||
	   first.seconds != second.seconds {return}
	tail := strings.trim_left(body[end + 1:], " \t")
	if !strings.has_prefix(tail, "(<t:") ||
	   !strings.has_suffix(tail, ">)") ||
	   strings.index_byte(tail, '>') != len(tail) - 2 {return}
	if strings.trim_space(block.text[first.end:second.start]) != "(" ||
	   strings.trim_space(block.text[second.end:]) != ")" {return}
	return first, true
}

@(private)
timestamp_card :: proc(index: u32, msg: Msg_Ui) -> bool {
	stamp, paired := standalone_timestamp(msg.body, msg.blocks[:])
	if stamp == nil {return false}
	local: Local_Time
	if wn_timestamp_local(stamp.seconds, &local) == 0 {return false}
	now := time.time_to_unix(time.now())
	label, detail: string
	if stamp.style == .RELATIVE {
		label = timestamp_relative(stamp.seconds, now)
		detail = timestamp_absolute(local, .LONG_DATE_TIME)
	} else {
		label = timestamp_absolute(local, stamp.style)
		if !paired && (stamp.style == .SHORT_TIME || stamp.style == .LONG_TIME) {
			detail = timestamp_absolute(local, .LONG_DATE)
		} else {
			detail = timestamp_relative(stamp.seconds, now)
		}
	}
	if nendo.box(nendo.id("MsgTimestamp", index))(
	{
		width = nendo.fit(max = att_w(360)),
		padding = nendo.pad(10),
		gap = 10,
		align = {y = .Center},
		color = PLATE,
		radius = rr(10),
		border = {color = FIELD_BORDER, width = bw()},
	},
	) {
		if hovered() {
			timestamp_tooltip(stamp, paired ? strings.trim_space(msg.body) : "")
		}
		if nendo.box()(
		{
			width = nendo.fixed(34),
			height = nendo.fixed(34),
			align = {x = .Center, y = .Center},
			color = ACCENT,
			radius = rr(8),
		},
		) {
			nendo.text(TIMESTAMP_ICON, {font = FONT_ICON, size = 17, color = ON_ACCENT})
		}
		if nendo.box()({direction = .Column, gap = 2}) {
			nendo.text(label, {font = FONT_TITLE, size = 16, color = TEXT})
			nendo.text(detail, {font = FONT_BODY, size = 12, color = TEXT_DIM})
		}
	}
	return true
}
