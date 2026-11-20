package main

import "core:fmt"
import "core:strings"

import "nendo"

@(private)
youtube_hover: string

// Only the validated video ID, never the sender's URL, goes to WebKit.
@(private)
youtube_id :: proc(url: string) -> string {
	scheme, sep, rest := strings.partition(url, "://")
	if sep == "" || (scheme != "https" && scheme != "http") {return ""}
	host, slash, tail := strings.partition(rest, "/")
	if slash == "" {return ""}
	tail, _, _ = strings.partition(tail, "#")
	path, _, query := strings.partition(tail, "?")

	video: string
	switch host {
	case "youtu.be", "www.youtu.be":
		video = path
	case "youtube.com", "www.youtube.com", "m.youtube.com":
		if path == "watch" {
			for part in strings.split_iterator(&query, "&") {
				if strings.has_prefix(part, "v=") {video = part[2:]; break}
			}
		} else {
			kind, _, id := strings.partition(path, "/")
			if kind == "shorts" || kind == "live" || kind == "embed" {video = id}
		}
	case "youtube-nocookie.com", "www.youtube-nocookie.com":
		kind, _, id := strings.partition(path, "/")
		if kind == "embed" {video = id}
	}
	if len(video) != 11 {return ""}
	for c in transmute([]u8)video {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_':
		case:
			return ""
		}
	}
	return video
}

@(private)
youtube_card :: proc(id: u32, url, video: string) {
	if nendo.box(nendo.id("YouTubeCard", id))(
	{
		width = nendo.fixed(att_w(280)),
		direction = .Column,
		gap = 6,
		padding = nendo.pad(8),
		color = PLATE,
		radius = rr(10),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		if nendo.box(nendo.id("YouTubePlay", id))(
		{
			width = nendo.grow(),
			height = nendo.fit(tap_min()),
			gap = 8,
			padding = nendo.pad(8),
			align = {x = .Center, y = .Center},
			color = hovered() ? HOVER : ROW_BG,
			radius = rr(6),
		},
		) {
			if hovered() {youtube_hover = video; cursor_raise(.Pointer)}
			nendo.text("\uf04b", {font = FONT_ICON, size = 13, color = ACCENT})
			nendo.text(tr("Play YouTube video"), {font = FONT_BODY, size = 13, color = TEXT})
		}
		if nendo.box(nendo.id("YouTubeLink", id))({padding = nendo.pad(6)}) {
			if hovered() {link_hover = url; cursor_raise(.Pointer); tooltip(url)}
			nendo.text(tr("Open in browser"), {font = FONT_BODY, size = 12, color = ACCENT})
		}
	}
}

@(private)
youtube_play :: proc(ui: ^Ui_State, video: string) {
	url := fmt.tprintf("https://www.youtube-nocookie.com/embed/%s?autoplay=1&fs=0", video)
	if !web_open(url, "YouTube", .YouTube) {
		toast(ui, fmt.tprintf(tr("Couldn't open %s. Please try again."), "YouTube"))
	}
}
