// Where the bundled runtime data lives: the Twemoji tiles, the emoji
// picker catalog, and the fonts a packaged build ships.
//
// Packaged resources live in usr/share on Linux, resources beside the
// executable on Windows, and Contents/Resources inside the macOS app.
// A dev build falls back to the vendor tree staged by scripts/build.sh.
package main

import "core:os"
import "core:path/filepath"
import "core:strings"

when ODIN_OS == .Windows {
	foreign import bundle_crt "system:ucrt"
	@(private = "file")
	foreign bundle_crt {
		@(link_name = "_putenv_s")
		set_c_env :: proc "c" (key, value: cstring) -> i32 ---
	}
}

@(private = "file")
DEV_RES :: #directory + "/../vendor"

@(private = "file")
g_res: string

@(private)
WN_BUILD_DIR ::
	"../build" when #config(WN_TARGET, "") == "" else "../build/cross/" + #config(WN_TARGET, "")

@(private)
WN_CXX_LIBRARY :: "system:stdc++" when ODIN_OS == .Linux else "system:c++"

// The bundled-data directory, resolved once from the running binary.
res_dir :: proc() -> string {
	if g_res != "" {
		return g_res
	}
	g_res = DEV_RES
	exe := executable_path()
	if exe == "" {
		return g_res
	}
	parts := []string{filepath.dir(filepath.dir(exe)), "share", "whitenoise-linux"}
	when ODIN_OS == .Windows {
		parts = {filepath.dir(exe), "resources"}
	} else when ODIN_OS == .Darwin {
		parts = {filepath.dir(filepath.dir(exe)), "Resources", "whitenoise-linux"}
	}
	share, jerr := filepath.join(parts)
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

@(private)
executable_path :: proc(allocator := context.temp_allocator) -> string {
	path, err := os.get_executable_path(allocator)
	if err != nil {return ""}
	return path
}

@(private)
helper_path :: proc(name: string) -> string {
	exe := executable_path()
	if exe == "" {return ""}
	filename := name
	when ODIN_OS == .Windows {filename = strings.concatenate({name, ".exe"}, context.temp_allocator)}
	path, err := filepath.join({filepath.dir(exe), filename}, context.temp_allocator)
	if err != nil {return ""}
	if !os.is_file(path) {
		bundled, bundle_err := filepath.join({res_dir(), filename}, context.temp_allocator)
		if bundle_err == nil && os.is_file(bundled) {return bundled}
	}
	return path
}

@(private)
curl_path :: proc() -> string {
	bundled := helper_path("curl")
	return os.exists(bundled) ? bundled : "curl"
}

@(private)
configure_bundle_environment :: proc() {
	when ODIN_OS == .Windows || ODIN_OS == .Darwin {
		fonts, err := filepath.join({res_dir(), "fonts.conf"}, context.temp_allocator)
		if err == nil &&
		   os.exists(fonts) &&
		   os.get_env("FONTCONFIG_FILE", context.temp_allocator) == "" {
			when ODIN_OS == .Windows {
				// Fontconfig reads UCRT's environment, not the Win32 environment.
				set_c_env(
					"FONTCONFIG_FILE",
					strings.clone_to_cstring(fonts, context.temp_allocator),
				)
			}
			os.set_env("FONTCONFIG_FILE", fonts)
		}
	}
	when ODIN_OS == .Darwin {
		cert, cert_err := filepath.join({res_dir(), "cacert.pem"}, context.temp_allocator)
		if cert_err != nil || !os.exists(cert) {return}
		for key in ([]string{"SSL_CERT_FILE", "CURL_CA_BUNDLE"}) {
			if os.get_env(key, context.temp_allocator) == "" {os.set_env(key, cert)}
		}
	}
}
