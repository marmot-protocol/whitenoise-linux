#+build linux
package main

import "core:strings"
import "core:testing"

when ODIN_PLATFORM_SUBTARGET != .Android {
	@(test)
	appimage_host_env_ownership :: proc(t: ^testing.T) {
		root :: "/proc/123/fd/9"
		tools :: root + "/usr/libexec/host-tools:"
		owned := [?]string {
			"APPDIR=/tmp/old:mount",
			"WN_APPIMAGE_AUDIO_ROOT=" + root,
			"PIPEWIRE_MODULE_DIR=" + root + "/usr/lib",
			"WN_APPIMAGE_AUDIO_CONF=client.conf",
			"SPA_PLUGIN_DIR=" + root + "/usr/lib/spa-0.2",
			"PIPEWIRE_CONFIG_NAME=client.conf",
			"PATH=" + tools + ":/usr/bin",
			"PIPEWIRE_REMOTE=host",
		}
		testing.expect_value(
			t,
			strings.join(strip_appimage_env(owned[:]), "\n", context.temp_allocator),
			"APPDIR=/tmp/old:mount\nPATH=:/usr/bin\nPIPEWIRE_REMOTE=host",
		)
		host := [?]string {
			"WN_APPIMAGE_AUDIO_ROOT=" + root,
			"PIPEWIRE_MODULE_DIR=" + root + "/usr/lib64",
			"WN_APPIMAGE_AUDIO_CONF=client.conf",
			"PIPEWIRE_CONFIG_NAME=client.conf.custom",
			"SPA_PLUGIN_DIR=/host plugins",
			"PATH=/host bin:" + tools + "/usr/bin",
		}
		testing.expect_value(
			t,
			strings.join(strip_appimage_env(host[:]), "\n", context.temp_allocator),
			"PIPEWIRE_MODULE_DIR=" +
			root +
			"/usr/lib64\n" +
			"PIPEWIRE_CONFIG_NAME=client.conf.custom\nSPA_PLUGIN_DIR=/host plugins\n" +
			"PATH=/host bin:" +
			tools +
			"/usr/bin",
		)
	}
}
