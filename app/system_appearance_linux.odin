package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

foreign import gio {"system:gio-2.0", "system:gobject-2.0", "system:glib-2.0"}

@(private)
foreign gio {
	g_cancellable_new :: proc "c" () -> rawptr ---
	g_cancellable_cancel :: proc "c" (cancellable: rawptr) ---
	g_object_unref :: proc "c" (object: rawptr) ---
}

@(private = "file")
foreign gio {
	g_dbus_connection_new_for_address_sync :: proc "c" (address: cstring, flags: c.int, observer, cancellable, error: rawptr) -> rawptr ---
	g_dbus_address_escape_value :: proc "c" (value: cstring) -> cstring ---
	g_free :: proc "c" (value: rawptr) ---
	g_dbus_connection_call_sync :: proc "c" (bus: rawptr, destination, path, interface, method: cstring, args, reply_type: rawptr, flags, timeout_ms: c.int, cancellable, error: rawptr) -> rawptr ---
	g_variant_new_tuple :: proc "c" (children: [^]rawptr, count: c.size_t) -> rawptr ---
	g_variant_new_string :: proc "c" (value: cstring) -> rawptr ---
	g_variant_get_child_value :: proc "c" (value: rawptr, index: c.size_t) -> rawptr ---
	g_variant_get_variant :: proc "c" (value: rawptr) -> rawptr ---
	g_variant_get_type_string :: proc "c" (value: rawptr) -> cstring ---
	g_variant_get_boolean :: proc "c" (value: rawptr) -> c.int ---
	g_variant_get_uint32 :: proc "c" (value: rawptr) -> u32 ---
	g_variant_get_string :: proc "c" (value: rawptr, length: rawptr) -> cstring ---
	g_variant_unref :: proc "c" (value: rawptr) ---
}

@(private = "file")
read_setting :: proc(
	bus, cancel: rawptr,
	namespace, key, kind: cstring,
) -> (
	value: u32,
	ok: bool,
) {
	args := [?]rawptr{g_variant_new_string(namespace), g_variant_new_string(key)}
	reply := g_dbus_connection_call_sync(
		bus,
		"org.freedesktop.portal.Desktop",
		"/org/freedesktop/portal/desktop",
		"org.freedesktop.portal.Settings",
		"ReadOne",
		g_variant_new_tuple(raw_data(args[:]), len(args)),
		nil,
		0,
		250,
		cancel,
		nil,
	)
	if reply == nil {return}
	defer g_variant_unref(reply)
	if string(g_variant_get_type_string(reply)) != "(v)" {return}
	box := g_variant_get_child_value(reply, 0)
	defer g_variant_unref(box)
	data := g_variant_get_variant(box)
	defer g_variant_unref(data)
	if string(g_variant_get_type_string(data)) != string(kind) {return}
	switch string(kind) {
	case "b":
		return u32(g_variant_get_boolean(data)), true
	case "u":
		return g_variant_get_uint32(data), true
	case "s":
		switch string(g_variant_get_string(data, nil)) {
		case "prefer-dark":
			return 1, true
		case "default", "prefer-light":
			return 2, true
		}
	}
	return
}

// The settings portal exposes Din's GTK preferences even in a Flatpak.
@(private)
read_din_appearance :: proc(cancel: rawptr = nil) -> (appearance: System_Appearance) {
	address := os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator)
	if address == "" {
		runtime_dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
		if !strings.has_prefix(runtime_dir, "/") {return}
		path := fmt.ctprintf("%s/bus", runtime_dir)
		escaped := g_dbus_address_escape_value(path)
		defer g_free(rawptr(escaped))
		address = fmt.tprintf("unix:path=%s", string(escaped))
	}
	// Only use local Unix endpoints. Autolaunch and nonce-file reads
	// do not honor cancellation.
	AUTHENTICATED_BUS :: 0x01 | 0x08 // AUTHENTICATION_CLIENT | MESSAGE_BUS_CONNECTION
	bus: rawptr
	for addr in strings.split_iterator(&address, ";") {
		if !strings.has_prefix(addr, "unix:") {continue}
		bus = g_dbus_connection_new_for_address_sync(
			strings.clone_to_cstring(addr, context.temp_allocator),
			AUTHENTICATED_BUS,
			nil,
			cancel,
			nil,
		)
		if bus != nil {break}
	}
	if bus == nil {return}
	defer g_object_unref(bus)
	if animations, ok := read_setting(
		bus,
		cancel,
		"org.gnome.desktop.interface",
		"enable-animations",
		"b",
	); ok {
		appearance.reduce_motion = animations == 0
		appearance.motion_known = true
	}
	if contrast, ok := read_setting(
		bus,
		cancel,
		"org.gnome.desktop.a11y.interface",
		"high-contrast",
		"b",
	); ok {
		appearance.high_contrast = contrast != 0
		appearance.contrast_known = true
	} else if contrast, ok := read_setting(
		bus,
		cancel,
		"org.freedesktop.appearance",
		"contrast",
		"u",
	); ok && contrast <= 1 {
		appearance.high_contrast = contrast == 1
		appearance.contrast_known = true
	}
	scheme, _ := read_setting(bus, cancel, "org.freedesktop.appearance", "color-scheme", "u")
	if scheme == 0 {
		// Din publishes its light theme as GNOME's "default".
		scheme, _ = read_setting(bus, cancel, "org.gnome.desktop.interface", "color-scheme", "s")
	}
	switch scheme {
	case 1:
		appearance.tone = .Dark
	case 2:
		appearance.tone = .Light
	}
	return
}
