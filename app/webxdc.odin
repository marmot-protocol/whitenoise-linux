// Webxdc apps (NIP-DC): a .xdc attachment is a zip holding index.html,
// manifest.toml and an icon. Listing it as a plain archive says
// nothing, so it gets its own tile: icon, app name, and the honest
// note that nothing runs here yet.
//
// ponytail: identification only. Running the app needs an HTML engine
// (loopback server + system browser, or an embedded webview) and a
// transport for sendUpdate(); marmot-c sends no custom kinds or tags
// today, so the kind-4932 half has nowhere to go either.
package main

import "core:strings"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

XDC_ICON_PX :: 48

Xdc_View :: struct {
	arc:        ^Arc_View, // the unpacked zip, owns the bytes
	name:       string, // manifest name, else the file name
	icon:       rl.Texture2D,
	icon_image: rl.Image, // worker pixels until the UI uploads them
	has_icon:   bool,
}

is_xdc_name :: proc(lower: string) -> bool {
	return strings.has_suffix(lower, ".xdc")
}

// `name = "My App"` out of manifest.toml. Everything else in the
// manifest (source_code_url, request_integration) is unused here.
xdc_manifest_name :: proc(manifest: string) -> string {
	rest := manifest
	for line in strings.split_lines_iterator(&rest) {
		key, _, value := strings.partition(strings.trim_space(line), "=")
		if strings.trim_space(key) != "name" {
			continue
		}
		return strings.trim(strings.trim_space(value), "\"'")
	}
	return ""
}

// data ownership transfers to the view. nil = not a webxdc app, and
// the caller falls back to the plain file chip.
xdc_view_make :: proc(data: []u8, file_name: string, phase: Media_Phase = .Present) -> ^Xdc_View {
	arc := arc_view_make(data)
	if arc == nil {
		return nil
	}

	has_index := false
	manifest_at, icon_at := -1, -1
	for entry in arc.entries {
		switch strings.to_lower(entry.name, context.temp_allocator) {
		case "index.html":
			has_index = true
		case "manifest.toml":
			manifest_at = entry.index
		case "icon.png", "icon.jpg", "icon.jpeg":
			if icon_at < 0 {
				icon_at = entry.index
			}
		}
	}

	// index.html is the whole contract: without it there is no app.
	if !has_index {
		arc.data = nil // ownership transfers only on success
		arc_view_free(arc)
		return nil
	}

	view := new(Xdc_View)
	view.arc = arc
	view.name = strings.clone(file_name)

	if manifest_at >= 0 {
		if bytes, ok := arc_entry_bytes(arc, manifest_at); ok {
			defer delete(bytes)
			if name := xdc_manifest_name(string(bytes)); name != "" {
				delete(view.name)
				view.name = strings.clone(name)
			}
		}
	}

	if icon_at >= 0 {
		if bytes, ok := arc_entry_bytes(arc, icon_at); ok {
			defer delete(bytes)
			// stbi sniffs the format; the ext hint is unused.
			image := rl.LoadImageFromMemory(".png", raw_data(bytes), i32(len(bytes)))
			if image.data != nil {
				if phase == .Present {
					view.icon = rl.LoadTextureFromImage(image)
					rl.UnloadImage(image)
				} else {
					view.icon_image = image
				}
				view.has_icon = true
			}
		}
	}
	return view
}

// Icon, app name, and the note. Sized and plated like the other
// attachment tiles.
// The Open button under the pointer, rebound every build like
// arc_hover.
Xdc_Hover :: struct {
	view:   ^Xdc_View,
	msg_id: string,
}
xdc_hover: Xdc_Hover

// The webxdc session is identified by the message that shared the app,
// so every member of the group derives the same one without an imeta
// tag (NIP-DC's `webxdc` param, which marmot-c cannot write).
handle_xdc_click :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if !mouse_released() || xdc_hover.view == nil || ui.selected < 0 {
		return
	}
	xdc_launch(ui, client, xdc_hover.view, xdc_hover.msg_id, ui.chats[ui.selected].group_id)
}

xdc_tile :: proc(view: ^Xdc_View, id: u32, msg_id: string, att: int, file_name: string) {
	if clay.UI(clay.ID("MsgXdc", id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(320)},
			padding = clay.PaddingAll(10),
			childGap = 10,
			childAlignment = {y = .Center},
		},
		backgroundColor = PLATE,
		cornerRadius = rr(8),
	},
	) {
		att_dl_button("DlXdc", id, msg_id, att, file_name)
		if view.has_icon {
			if clay.UI(clay.ID("MsgXdcIcon", id))(
			{
				layout = {
					sizing = {
						width = clay.SizingFixed(XDC_ICON_PX),
						height = clay.SizingFixed(XDC_ICON_PX),
					},
				},
				image = {imageData = &view.icon},
				cornerRadius = rr(10),
			},
			) {}
		}
		if clay.UI(clay.ID("MsgXdcText", id))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow()},
				childGap = 2,
			},
		},
		) {
			clay.Text(view.name, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
			clay.Text(tr("Webxdc app"), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
		}
		// Opens in the system browser, served from memory.
		if clay.UI(clay.ID("MsgXdcOpen", id))(
		{
			layout = {padding = {left = 12, right = 12, top = 6, bottom = 6}},
			backgroundColor = hovered() ? ACCENT : ROW_BG,
			cornerRadius = rr(6),
		},
		) {
			if hovered() {
				xdc_hover = {view, msg_id}
			}
			clay.Text(tr("Open"), {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})
		}
	}
}
