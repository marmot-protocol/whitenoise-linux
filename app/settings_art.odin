package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Every illustration settings draws: one per category, plus one per
// property page that no category picture already describes.
@(private)
Settings_Art :: enum {
	Home,
	General,
	Folders,
	Speech,
	Network,
	Keys,
	Appearance,
	Notifications,
	Storage,
	Advanced,
	About,
	Startup,
	Language,
	Messaging,
	Interface,
	Avatars,
	Read_Aloud,
	Linked_Events,
	Key_Packages,
	Security,
	Privacy,
	Audit_Logs,
	Agents,
}

// Debug and KP reuse the toolbox and identity illustrations respectively.
@(private)
SECTION_ART := [Settings_Section]Settings_Art {
	.Home          = .Home,
	.General       = .General,
	.Folders       = .Folders,
	.Speech        = .Speech,
	.Network       = .Network,
	.Keys          = .Keys,
	.Appearance    = .Appearance,
	.Notifications = .Notifications,
	.Storage       = .Storage,
	.Advanced      = .Advanced,
	.About         = .About,
	.Debug         = .Advanced,
	.KP            = .Keys,
	.Agents        = .Agents,
}

// Original artwork. SVG sources and the embedded transparent PNGs live
// together under assets/settings and share the project's AGPL v3 license.
@(private = "file")
SETTINGS_ART := [Settings_Art]struct {
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
	.Startup       = {"settings-art://startup", #load("assets/settings/startup.png")},
	.Language      = {"settings-art://language", #load("assets/settings/language.png")},
	.Messaging     = {"settings-art://messaging", #load("assets/settings/messaging.png")},
	.Interface     = {"settings-art://interface", #load("assets/settings/interface.png")},
	.Avatars       = {"settings-art://avatars", #load("assets/settings/avatars.png")},
	.Read_Aloud    = {"settings-art://read-aloud", #load("assets/settings/read-aloud.png")},
	.Linked_Events = {"settings-art://linked-events", #load("assets/settings/linked-events.png")},
	.Key_Packages  = {"settings-art://key-packages", #load("assets/settings/key-packages.png")},
	.Security      = {"settings-art://security", #load("assets/settings/security.png")},
	.Privacy       = {"settings-art://privacy", #load("assets/settings/privacy.png")},
	.Audit_Logs    = {"settings-art://audit-logs", #load("assets/settings/audit-logs.png")},
	.Agents        = {"settings-art://agents", #load("assets/settings/agents.png")},
}

@(private)
settings_illustration :: proc(id: string, which: Settings_Art, size: f32) {
	art := SETTINGS_ART[which]
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
