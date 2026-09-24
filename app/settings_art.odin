package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Original category artwork. SVG sources and the embedded transparent PNGs
// live together under assets/settings and share the project's AGPL v3 license.
// Debug and KP reuse the toolbox and identity illustrations respectively.
@(private = "file")
SETTINGS_ART := [Settings_Section]struct {
	url: string,
	png: []u8,
} {
	.Home          = {"settings-art://home", #load("assets/settings/home.png")},
	.General       = {"settings-art://general", #load("assets/settings/general.png")},
	.Folders       = {"settings-art://folders", #load("assets/settings/folders.png")},
	.Speech        = {"settings-art://speech", #load("assets/settings/speech.png")},
	.Network       = {"settings-art://network", #load("assets/settings/network.png")},
	.Keys          = {"settings-art://keys", #load("assets/settings/keys.png")},
	.Appearance    = {"settings-art://appearance", #load("assets/settings/appearance.png")},
	.Notifications = {"settings-art://notifications", #load("assets/settings/notifications.png")},
	.Storage       = {"settings-art://storage", #load("assets/settings/storage.png")},
	.Advanced      = {"settings-art://advanced", #load("assets/settings/advanced.png")},
	.About         = {"settings-art://about", #load("assets/settings/about.png")},
	.Debug         = {},
	.KP            = {},
}

@(private)
settings_illustration :: proc(id: string, section: Settings_Section, size: f32) {
	section := section
	if section == .Debug {section = .Advanced}
	if section == .KP {section = .Keys}
	art := SETTINGS_ART[section]
	tex := local_pic(art.url)
	if tex == nil {
		image := rl.LoadImageFromMemory(".png", raw_data(art.png), i32(len(art.png)))
		if image.data != nil {
			register_local_pic(art.url, image)
			rl.UnloadImage(image)
			tex = local_pic(art.url)
		}
	}
	// The existing picture registry owns the source and its mask variants.
	// Its square variant keeps the full transparent illustration, rather than
	// the default circular avatar crop. SDL tracks both textures for reload
	// teardown, and the reload heap owns their retained pixels and map entries.
	tex = shaped_avatar(tex, "square")
	if clay.UI(clay.ID(id))(
	{
		layout = {sizing = {width = clay.SizingFixed(size), height = clay.SizingFixed(size)}},
		image = {imageData = tex},
	},
	) {}
}
