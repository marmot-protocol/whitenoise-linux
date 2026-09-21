package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

@(test)
profile_picture_cache :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	previous_home, previous_vault := data_home, g_vault
	data_home = fmt.tprintf("/tmp/wn-profile-cache-%d", time.now()._nsec)
	g_vault = {
		unlocked = true,
	}
	defer {data_home, g_vault = previous_home, previous_vault}
	os.make_directory(data_home)
	defer os.remove_all(data_home)
	source := fmt.tprintf("%s/picture", data_home)
	url := fmt.tprintf("file://%s", source)
	first := "first picture bytes"
	second := "updated picture bytes"
	testing.expect(t, os.write_entire_file(source, transmute([]u8)first) == nil)
	data := pic_load(url)
	testing.expect_value(t, string(data), first)
	delete(data)
	path := pic_cache_path(url)
	sealed, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil && !strings.contains(string(sealed), first))
	info, stat_err := os.stat(path, context.temp_allocator)
	testing.expect(
		t,
		stat_err == nil &&
		info.mode & {.Read_Group, .Write_Group, .Read_Other, .Write_Other} == {},
	)
	os.remove(source)
	data = pic_load(url)
	testing.expect(t, string(data) == first, "cached picture survives an unavailable source")
	delete(data)
	testing.expect(t, os.write_entire_file(source, transmute([]u8)second) == nil)
	data = pic_load(url)
	testing.expect(t, string(data) == first, "fresh cache avoids fetching changed source bytes")
	delete(data)
	old := time.time_add(time.now(), -25 * time.Hour)
	testing.expect(t, os.change_times(path, old, old) == nil)
	data = pic_load(url)
	testing.expect(t, string(data) == second, "expired URL fetches its updated contents")
	delete(data)
	os.remove(source)
	testing.expect(t, os.change_times(path, old, old) == nil)
	data = pic_load(url)
	testing.expect(t, string(data) == second, "expired picture stays available offline")
	delete(data)
	g_vault.key[0] = 1
	data = pic_load(url)
	testing.expect(t, len(data) == 0, "a different vault cannot open the cached image")
	delete(data)
}
