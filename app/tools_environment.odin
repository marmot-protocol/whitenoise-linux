#+build !openbsd
package main

import "core:fmt"
import "core:os"
import "core:strings"

// OpenBSD sends credentials to its broker instead of changing a child's environment.
@(private)
proxy_child_env :: proc(
	source: []string,
	proxy: string,
) -> (
	environment: []string,
	err: os.Error,
) {
	source := source
	if source == nil {
		source, err = os.environ(context.temp_allocator)
		if err != nil {return nil, err}
	}
	env := make([dynamic]string, context.temp_allocator)
	for entry in source {
		separator := strings.index_byte(entry, '=')
		if separator < 0 {continue}
		key := entry[:separator]
		if strings.has_suffix(key, "_proxy") || strings.has_suffix(key, "_PROXY") {
			continue
		}
		append(&env, entry)
	}
	append(&env, fmt.tprintf("all_proxy=%s", proxy))
	return env[:], nil
}
