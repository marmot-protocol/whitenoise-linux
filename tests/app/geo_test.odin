package main

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

@(test)
geo_links :: proc(t: ^testing.T) {
	Links :: struct {
		url:  string,
		link: Geo_Link,
	}
	for c in ([]Links {
			{"https://maps.google.com/maps?q=38.8976763,-116.0599673", {{38.8976763, -116.0599673}, 0}},
			{"https://maps.google.com/?q=-33.868820%2c151.209290", {{-33.86882, 151.20929}, 0}},
			{"https://www.google.com/maps/search/?api=1&query=52.5%2C13.4", {{52.5, 13.4}, 0}},
			{"https://maps.apple.com/place?coordinate=52.5%2C13.4", {{52.5, 13.4}, 0}},
			{"https://maps.apple.com/?q=Here&ll=52.5,13.4&z=11.6", {{52.5, 13.4}, 12}},
			// The marker wins over the view; the view gives the zoom.
			{"https://www.openstreetmap.org/?mlat=0&mlon=0#map=12/0.0000/0.0000", {{0, 0}, 12}},
			{"https://www.openstreetmap.org/?mlat=1.5&mlon=-2#map=9/4/5&layers=C", {{1.5, -2}, 9}},
			{"https://www.openstreetmap.org/#map=12/48.85/2.35", {{48.85, 2.35}, 12}},
			{"https://kagi.com/maps/#14.58/0/0", {{0, 0}, 15}},
			{"https://kagi.com/maps/#0.4/10/20", {{10, 20}, 2}},
			{"https://kagi.com/maps/pins/52.5,13.4,Brandenburg%20Gate/48.8,2.3", {{52.5, 13.4}, 0}},
			{"https://kagi.com/maps/pins/52.5,13.4", {{52.5, 13.4}, 0}},
			// Google: the place's own pin wins over the offset view center.
			{"https://www.google.com/maps/place/Casa+Bianca/@38.8976763,-77.0391101,17z/data=!3m1!4b1!4m6!3m5!1s0x89b7b7bcdecbb1df:0x715969d86d0b76bf!8m2!3d38.8976763!4d-77.0365298!16zL20vMDgxc3E?entry=ttu&g_ep=EgoyMDI2MDkzMC4wIKXMDSoASAFQAw%3D%3D", {{38.8976763, -77.0365298}, 17}},
			{"https://www.google.com/maps/@48.8584,2.2945,15z", {{48.8584, 2.2945}, 15}},
			{"https://www.google.com/maps/@48.8584,2.2945,3a,75y,90t/data=!3m6", {{48.8584, 2.2945}, 0}},
			// Search pages: the hash view wins over stale search params.
			{"https://kagi.com/maps/search?q=white%20house%2C%20washington&ll=0.000000,0.000000&z=14.58#18.5/38.8976763/-77.0365298/0/40", {{38.8976763, -77.0365298}, 19}},
			{"https://kagi.com/maps/search?q=x&ll=48.8,2.3&z=11", {{48.8, 2.3}, 11}},
			{"https://www.openstreetmap.org/search?query=white+house+washington&zoom=12&minlon=-0.46897888183593756&minlat=-0.16616797994936602&maxlon=0.46897888183593756&maxlat=0.16582465863634066#map=19/38.897643/-77.036552", {{38.897643, -77.036552}, 19}},
		}) {
		link, ok := geo_ref(c.url)
		testing.expect(t, ok, c.url)
		testing.expect_value(t, link, c.link)
	}
	for url in ([]string{"https://maps.google.com/maps?q=90.1,0", "https://maps.google.com/maps?q=0,180.5", "https://maps.google.com/maps?q=1e2,3", "https://maps.google.com/maps?q=+1,3", "https://maps.google.com/maps?q=1.,3", "https://maps.google.com/maps?q=.5,3", "https://maps.google.com/maps?q=1,2,3", "https://maps.google.com/maps?q=1,2&z=4", "https://maps.google.com/maps?q=Berlin", "https://maps.google.com.evil/maps?q=1,2", "http://maps.google.com/maps?q=1,2", "https://maps.google.com/maps?q=", "https://maps.google.com/maps?q=1", "https://www.openstreetmap.org/way/123", "https://www.openstreetmap.org/?mlat=0#map=12/0/0x", "https://www.openstreetmap.org/#map=12/91/0", "https://kagi.com/maps/", "https://kagi.com/maps/#-1/0/0", "https://kagi.com/maps/search?q=Berlin", "https://kagi.com/maps/pins/Berlin", "https://maps.apple.com/?q=Berlin", "https://www.google.com/maps/place/Casa+Bianca", "https://www.google.com/search?q=0,0", "https://www.google.com.evil/maps/@1,2,3z"}) {
		_, ok := geo_ref(url)
		testing.expect(t, !ok, url)
	}

	label := geo_place_parse(
		transmute([]u8)string(
			`{"address":{"town":"Beatty","county":"Nye County","country":"United States"}}`,
		),
	)
	defer delete(label)
	testing.expect_value(t, label, "Beatty, United States")
	for body in ([]string{`{"error":"Unable to geocode"}`, "null", "invalid"}) {
		empty := geo_place_parse(transmute([]u8)body)
		testing.expect_value(t, empty, "")
		delete(empty)
	}
}

// Android's "Location: <url>" shares one row with its card; prose
// before a location link keeps a row of its own.
@(test)
geo_card_lines :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	defer wrap_clear()
	url :: "https://maps.google.com/maps?q=52.520008,13.404954"
	shared := wrapped_lines("Location: " + url, 0, 14, .Cards)
	testing.expect_value(t, len(shared), 1)
	testing.expect_value(t, shared[0].start, 0)
	text := "Meet here: " + url
	lines := wrapped_lines(text, 0, 14, .Cards)
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, text[lines[1].start:lines[1].end], url)
}

// Every map site opens on the pin; OpenStreetMap without a map view
// opens at the card's zoom. Each link, pasted back, is a card again.
@(test)
geo_open_sites :: proc(t: ^testing.T) {
	ui: Ui_State
	g_ui = &ui
	defer g_ui = nil
	pin := Geo_Point{-33.86882, 151.20929}
	want := [Map_Browser]string {
		.OpenStreetMap = "https://www.openstreetmap.org/?mlat=-33.868820&mlon=151.209290#map=15/-33.86882/151.20929",
		.Apple_Maps    = "https://maps.apple.com/place?coordinate=-33.868820%2C151.209290",
		.Kagi_Maps     = "https://kagi.com/maps/pins/-33.868820,151.209290",
		.Google_Maps   = "https://www.google.com/maps/search/?api=1&query=-33.868820%2C151.209290",
	}
	for url, browser in want {
		ui.prefs.map_browser = browser
		got, _ := geo_open("geo-open-test", pin, 15)
		testing.expect_value(t, got, url)
		back, ok := geo_ref(got)
		testing.expect(t, ok, got)
		testing.expect_value(t, back.pin, pin)
	}
}

// The tile cache shares media-cache with attachments: a trim removes
// the oldest-fetched tiles first and never touches other files.
@(test)
geo_disk_trimming :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "wn-geo-trim-*", context.allocator)
	testing.expect(t, err == nil)
	defer {os.remove_all(dir); delete(dir)}
	block := make([]u8, 100)
	defer delete(block)
	now := time.now()
	// tile-0 is the oldest fetch, tile-3 the newest.
	for i in 0 ..< 4 {
		path := fmt.tprintf("%s/tile-%d.bin", dir, i)
		_ = os.write_entire_file(path, block)
		stamp := time.time_add(now, time.Duration(i - 10) * time.Hour)
		_ = os.change_times(path, stamp, stamp)
	}
	attachment := fmt.tprintf("%s/%s.bin", dir, "ab")
	_ = os.write_entire_file(attachment, block)
	_ = os.change_times(attachment, time.Time{}, time.Time{})

	testing.expect_value(t, geo_disk_trim(dir, 400), i64(400))
	testing.expect_value(t, geo_disk_trim(dir, 250), i64(200))
	for i in 0 ..< 4 {
		testing.expect_value(t, os.exists(fmt.tprintf("%s/tile-%d.bin", dir, i)), i >= 2)
	}
	testing.expect(t, os.exists(attachment))
}
