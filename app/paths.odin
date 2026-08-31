// Where the bundled runtime data lives: the Twemoji tiles, the emoji
// picker catalog, and the fonts a packaged build ships.
//
// An installed tree keeps them beside the binary, which is the layout
// the AppImage builds:
//
//   usr/bin/whitenoise-linux
//   usr/share/whitenoise-linux/twemoji/*.png
//   usr/share/whitenoise-linux/emoji-catalog.tsv
//   usr/share/whitenoise-linux/fonts/*.ttf
//
// A dev build has no such tree, so it falls back to the vendor dir
// build.sh staged next to the sources.
package main

import "core:os"
import "core:path/filepath"
import "core:strings"

@(private = "file")
DEV_RES :: #directory + "/../vendor"

@(private = "file")
g_res: string

// The bundled-data directory, resolved once from the running binary.
res_dir :: proc() -> string {
	if g_res != "" {
		return g_res
	}
	g_res = DEV_RES
	exe, err := os.read_link("/proc/self/exe", context.temp_allocator)
	if err != nil {
		return g_res
	}
	// <exe>/../share/whitenoise-linux, i.e. usr/bin → usr/share.
	share, jerr := filepath.join({filepath.dir(filepath.dir(exe)), "share", "whitenoise-linux"})
	if jerr != nil {
		return g_res
	}
	if os.is_dir(share) {
		g_res = share
	} else {
		delete(share)
	}
	return g_res
}

// Absolute path of one bundled font, for the head of a font stack. The
// system paths behind it in the stack cover a build running from source.
res_font :: proc(name: string) -> cstring {
	path, err := filepath.join({res_dir(), "fonts", name}, context.temp_allocator)
	if err != nil {
		return nil
	}
	return strings.clone_to_cstring(path)
}
