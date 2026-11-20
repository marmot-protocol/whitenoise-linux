package main

import "core:testing"

@(test)
youtube_link_formats :: proc(t: ^testing.T) {
	id :: "M7lc1UVf-VE"
	valid := [?]string {
		"https://www.youtube.com/watch?list=PL123&v=" + id + "&t=42",
		"https://youtu.be/" + id + "?si=123",
		"https://m.youtube.com/shorts/" + id,
		"https://youtube.com/live/" + id,
		"https://www.youtube-nocookie.com/embed/" + id,
	}
	for url in valid {
		testing.expect_value(t, youtube_id(url), id)
	}
	invalid := [?]string {
		"https://www.youtube.com.example.org/watch?v=" + id,
		"https://www.youtube.com@example.org/watch?v=" + id,
		"https://youtu.be/" + id + "/more",
		"https://youtube.com/watch#?v=" + id,
		"https://youtube.com/playlist?list=" + id,
		"https://youtube.com/watch?v=M7lc1UVf.VE",
	}
	for url in invalid {
		testing.expect_value(t, youtube_id(url), "")
	}
	_, _, call := jitsi_room("https://youtu.be/" + id)
	testing.expect(t, !call, "rendering a short YouTube link must not trigger a call probe")
}
