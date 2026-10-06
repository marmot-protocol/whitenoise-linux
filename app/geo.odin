// Shared locations: a maps link drawn as an OpenStreetMap card.
//
// Android shares a location as plain text (whitenoise-android
// LocationShare.kt), "Location: https://maps.google.com/maps?q=<lat>,<lon>".
// The link stays the wire format. Here it becomes a card: a map stitched
// from tile.openstreetmap.org tiles that pans by drag and zooms by wheel
// or buttons, the place name from Nominatim, and the coordinates. No
// request ever goes to Google.
// Links from OpenStreetMap, Kagi Maps, Apple Maps and Google Maps that
// name a point or a view draw the same card (geo_ref lists the shapes).
//
// Nothing is requested before the user accepts the disclosure that
// geo_consent draws in place of the first map (prefs.map_consent).
//
//   body URL ──geo_ref──▶ render_segs ──▶ geo_card ──▶ geo_map
//                                            │            │ visible tile missing
//                                     geo_place_worker   geo_tile_worker (GEO_FETCHES at once)
//                                            │            │ sealed disk cache, then network
//                                            └──▶ drain_geo ◀──┘
//
// Tiles are textures in memory (LRU, GEO_TILE_CAP) and sealed files in
// media-cache (GEO_DISK_CAP, oldest fetch evicted first).
//
// ponytail: standard 256 px tiles draw soft on HiDPI. Fetch zoom+1
// tiles and draw them at half size when that shows up.
package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private = "file")
GEO_TILE :: 256
@(private = "file")
GEO_ZOOM_MIN :: 2
@(private = "file")
GEO_ZOOM_MAX :: 19 // the deepest tile.openstreetmap.org serves
@(private = "file")
GEO_ZOOM_SHARE :: 15 // streets with names, about 1.2 km across a card
@(private = "file")
GEO_MAP_H :: 220
@(private = "file")
GEO_TILE_CAP :: 160 // 256x256 RGBA each, about 40 MiB
@(private = "file")
GEO_FETCHES :: 2 // tile requests in flight; the OSM tile policy asks for few
@(private = "file")
GEO_AGENT :: "WhiteNoiseLinux/1.0 (shared locations)"
@(private = "file")
GEO_DISK_CAP :: 1 << 30 // sealed tile files in media-cache
@(private = "file")
GEO_DISK_KEEP :: GEO_DISK_CAP / 10 * 9 // a trim stops here, so it runs about once per 100 MiB written
@(private = "file")
GEO_TILE_TTL :: 7 * 24 * time.Hour // older cached tiles are fetched again, and used if that fails

// What maps send where. The first map shows it as a consent panel, and
// Settings > Advanced shows it under the switch.
@(private)
GEO_DISCLOSURE := N_(
	"Show a map for each shared location. Map images load from tile.openstreetmap.org, which sees your IP address and the area you view. Place names load from nominatim.openstreetmap.org, which receives the location rounded to about 100 m. Map images are cached on this device, encrypted, up to 1 GB.",
)

// The text Android puts in front of the link. It is the wire format,
// so it is matched in English whatever the interface language.
@(private)
GEO_CAPTION :: "Location:"

// The site "Open in" sends a shared location to. Map tiles always come
// from OpenStreetMap; this only picks where the user opens the pin.
@(private)
Map_Browser :: enum {
	OpenStreetMap,
	Apple_Maps,
	Kagi_Maps,
	Google_Maps,
}

// Product names, never translated.
@(private)
MAP_BROWSER_NAMES := [Map_Browser]string {
	.OpenStreetMap = "OpenStreetMap",
	.Apple_Maps    = "Apple Maps",
	.Kagi_Maps     = "Kagi Maps",
	.Google_Maps   = "Google Maps",
}

@(private = "file")
MAP_BROWSER_OPEN := [Map_Browser]string {
	.OpenStreetMap = N_("Open in OpenStreetMap"),
	.Apple_Maps    = N_("Open in Apple Maps"),
	.Kagi_Maps     = N_("Open in Kagi Maps"),
	.Google_Maps   = N_("Open in Google Maps"),
}

@(private)
Geo_Point :: struct {
	lat, lon: f64,
}

// What a location link carries: the pin, and the zoom it was shared at
// (0 when the link has none, e.g. Android's).
@(private)
Geo_Link :: struct {
	pin:  Geo_Point,
	zoom: int,
}

// One card's map: what it shows, and where it started for Recenter.
// Positions are Web Mercator, both axes in [0, 1).
@(private = "file")
Geo_View :: struct {
	key:          string, // owned map key; hover and drag hold it across frames
	center, home: [2]f64,
	zoom, home_z: int,
	wheel:        f32, // wheel travel short of a whole zoom step
}

@(private = "file")
Geo_Tile_Key :: [3]i32 // zoom, x, y

@(private = "file")
Geo_Tile_State :: enum {
	Loading, // requested, or waiting for a fetch slot
	Ready,
	Failed,
}

@(private = "file")
Geo_Tile :: struct {
	tex:   ^rl.Texture2D,
	state: Geo_Tile_State,
	used:  u64, // geo_frame it last drew in, for eviction
}

@(private)
Geo_Action :: enum {
	None,
	Zoom_In,
	Zoom_Out,
	Recenter,
	Retry,
	Copy,
	Accept,
	Decline,
}

// Session state. Views and places are never evicted: one entry per
// shared location seen, like hn_cards.
@(private = "file")
geo_views: map[string]Geo_View
@(private = "file")
geo_tiles: map[Geo_Tile_Key]Geo_Tile
@(private = "file")
geo_places: map[string]string // "lat,lon,lang" → place, "" = pending or nothing there
@(private = "file")
geo_fetches: int
@(private = "file")
geo_place_busy: bool
@(private = "file")
geo_frame: u64
@(private = "file")
geo_declined: bool // "Not now" on the consent panel: no maps this session

@(private = "file")
geo_disk_mutex: sync.Mutex
@(private = "file")
geo_disk_bytes: i64 = -1 // sealed tile bytes on disk; -1 = not summed yet

@(private = "file")
geo_mutex: sync.Mutex
@(private = "file")
geo_tile_fresh: [dynamic]struct {
	key:  Geo_Tile_Key,
	data: []u8, // owned, nil = miss
}
@(private = "file")
geo_place_fresh: [dynamic]struct {
	key, label: string, // key is the geo_places key; label owned
}

// Pointer state, rebound by every build and read by handle_geo.
@(private)
geo_hover: string // view key of the map under the pointer
@(private)
geo_drag: string
@(private)
geo_action: Geo_Action
@(private = "file")
geo_hover_box: clay.BoundingBox
@(private = "file")
geo_grab: [2]f32
@(private = "file")
geo_action_key: string
@(private = "file")
geo_action_pin: Geo_Point

// ── parsing ─────────────────────────────────────────────────────────

// The location in a map link, or ok = false. Takes Android's share text
// and the links every "Open in" site produces, so a location opened in
// one client and pasted into a chat draws as a card again:
//
//   https://maps.google.com/maps?q=38.8976763,-116.0599673     Android
//   https://www.google.com/maps/search/?api=1&query=0%2C0
//   https://www.google.com/maps/<any page>/@0,0,17z[/data=...!3d0!4d0]  place pin wins
//   https://maps.apple.com/place?coordinate=0%2C0
//   https://maps.apple.com/?ll=0,0&z=12
//   https://www.openstreetmap.org/<any page>?mlat=0&mlon=0     marker wins
//   https://www.openstreetmap.org/<any page>#map=12/0/0        view center
//   https://kagi.com/maps/<any page>#14.58/0/0[/bearing/pitch]  view center
//   https://kagi.com/maps/pins/0,0,Name
//   https://kagi.com/maps/<any page>?ll=0,0&z=12
@(private)
geo_ref :: proc(url: string) -> (link: Geo_Link, ok: bool) {
	if !strings.has_prefix(url, "https://") {return}
	before, _, fragment := strings.partition(url[len("https://"):], "#")
	path, _, query := strings.partition(before, "?")
	host, _, page := strings.partition(path, "/")
	switch host {
	case "www.google.com", "google.com", "maps.google.com":
		return geo_google(page, query, fragment)
	case "maps.apple.com":
		key := page == "place" ? "coordinate" : "ll"
		if page != "place" && page != "" {return}
		link.pin = geo_pair(geo_param(query, key) or_return) or_return
		if z, has_z := geo_param(query, "z"); has_z {link.zoom, _ = geo_zoom_level(z)}
		return link, true
	case "www.openstreetmap.org", "openstreetmap.org":
		// Any page, /search included; #map=12/0/0&layers=C. A search's
		// zoom and bounding box params can differ from the view the
		// sender saw, so only the marker and the hash count.
		view, has_view := geo_view_hash(
			strings.has_prefix(fragment, "map=") ? fragment[len("map="):] : "",
		)
		lat, has_lat := geo_param(query, "mlat")
		lon, has_lon := geo_param(query, "mlon")
		if !has_lat || !has_lon {return view, has_view}
		link.pin.lat = geo_degrees(lat, 90) or_return
		link.pin.lon = geo_degrees(lon, 180) or_return
		link.zoom = view.zoom
		return link, true
	case "kagi.com":
		return geo_kagi(page, query, fragment)
	}
	return
}

// Google: Android's ?q=, the search API, and any /maps page with an
// @<lat>,<lon>,<zoom>z view (place, search, dir). The @ is the view
// center; a place's own pin, when there is one, is the last
// !3d<lat>!4d<lon> in its data blob.
@(private = "file")
geo_google :: proc(page, query, fragment: string) -> (link: Geo_Link, ok: bool) {
	switch {
	case page == "" || page == "maps":
		// Android's text: the whole query is the pin.
		if len(fragment) > 0 || !strings.has_prefix(query, "q=") {return}
		link.pin = geo_pair(query[len("q="):]) or_return
	case page == "maps/search/" || page == "maps/search":
		link.pin = geo_pair(geo_param(query, "query") or_return) or_return
	case strings.has_prefix(page, "maps/"):
		at := strings.index(page, "/@")
		if at < 0 {return}
		view, _, _ := strings.partition(page[at + 2:], "/")
		lat, _, rest := strings.partition(view, ",")
		lon, _, zoom := strings.partition(rest, ",")
		link.pin.lat = geo_degrees(lat, 90) or_return
		link.pin.lon = geo_degrees(lon, 180) or_return
		// "17z"; street view and satellite use other units ("3a", "850m").
		if strings.has_suffix(zoom, "z") {link.zoom, _ = geo_zoom_level(zoom[:len(zoom) - 1])}
		if d := strings.last_index(page, "!3d"); d >= 0 {
			pin_lat, _, after := strings.partition(page[d + len("!3d"):], "!4d")
			pin_lon, _, _ := strings.partition(after, "!")
			place_lat, lat_ok := geo_degrees(pin_lat, 90)
			place_lon, lon_ok := geo_degrees(pin_lon, 180)
			if lat_ok && lon_ok {link.pin = {place_lat, place_lon}}
		}
	case:
		return
	}
	return link, true
}

// Kagi: the view in the hash on any /maps page, the first of
// /maps/pins/<lat>,<lon>[,<name>][/<more pins>], or ?ll= and ?z=. The
// hash wins over ll: search links carry ll=0,0 beside the real view.
@(private = "file")
geo_kagi :: proc(page, query, fragment: string) -> (link: Geo_Link, ok: bool) {
	if page != "maps" && !strings.has_prefix(page, "maps/") {return}
	if view, has_view := geo_view_hash(fragment); has_view {return view, true}
	if strings.has_prefix(page, "maps/pins/") {
		pin, _, _ := strings.partition(page[len("maps/pins/"):], "/")
		lat, _, rest := strings.partition(pin, ",")
		lon, _, _ := strings.partition(rest, ",")
		link.pin.lat = geo_degrees(lat, 90) or_return
		link.pin.lon = geo_degrees(lon, 180) or_return
		return link, true
	}
	link.pin = geo_pair(geo_param(query, "ll") or_return) or_return
	if z, has_z := geo_param(query, "z"); has_z {link.zoom, _ = geo_zoom_level(z)}
	return link, true
}

// "<lat>,<lon>", with the comma plain or as %2C.
@(private = "file")
geo_pair :: proc(text: string) -> (pin: Geo_Point, ok: bool) {
	lat, comma, lon := strings.partition(text, ",")
	if len(comma) == 0 {
		cut := strings.index(strings.to_upper(text, context.temp_allocator), "%2C")
		if cut < 0 {return}
		lat, lon = text[:cut], text[cut + 3:]
	}
	pin.lat = geo_degrees(lat, 90) or_return
	pin.lon = geo_degrees(lon, 180) or_return
	return pin, true
}

// The value of `name` in an a=1&b=2 query.
@(private = "file")
geo_param :: proc(query, name: string) -> (value: string, ok: bool) {
	query := query
	for part in strings.split_iterator(&query, "&") {
		key, eq, val := strings.partition(part, "=")
		if len(eq) > 0 && key == name {return val, true}
	}
	return
}

// A "<zoom>/<lat>/<lon>" view, the map centered on the pin. Anything
// after an & (OSM's layers) or a further / (Kagi's bearing and pitch)
// is ignored.
@(private = "file")
geo_view_hash :: proc(text: string) -> (link: Geo_Link, ok: bool) {
	view, _, _ := strings.partition(text, "&")
	zoom, _, rest := strings.partition(view, "/")
	lat, _, after := strings.partition(rest, "/")
	lon, _, _ := strings.partition(after, "/")
	link.zoom = geo_zoom_level(zoom) or_return
	link.pin.lat = geo_degrees(lat, 90) or_return
	link.pin.lon = geo_degrees(lon, 180) or_return
	return link, true
}

// A shared zoom ("14.58") as a whole tile level the card can draw.
@(private = "file")
geo_zoom_level :: proc(text: string) -> (zoom: int, ok: bool) {
	level := geo_degrees(text, 30) or_return
	if level < 0 {return}
	return clamp(int(math.round(level)), GEO_ZOOM_MIN, GEO_ZOOM_MAX), true
}

// Plain decimal degrees within ±limit. strconv alone would also take
// "1e2", "+5" and "inf".
@(private = "file")
geo_degrees :: proc(text: string, limit: f64) -> (value: f64, ok: bool) {
	digits := strings.trim_prefix(text, "-")
	dots := 0
	for c, i in digits {
		if c == '.' && i > 0 && i < len(digits) - 1 {dots += 1; continue}
		if c < '0' || c > '9' {return}
	}
	if len(digits) == 0 || dots > 1 {return}
	value = strconv.parse_f64(text) or_return
	return value, abs(value) <= limit
}

// ── projection ──────────────────────────────────────────────────────

@(private = "file")
geo_project :: proc(pin: Geo_Point) -> [2]f64 {
	lat := clamp(pin.lat, -85.05112878, 85.05112878) * math.PI / 180
	return {(pin.lon + 180) / 360, (1 - math.ln(math.tan(lat) + 1 / math.cos(lat)) / math.PI) / 2}
}

@(private = "file")
geo_unproject :: proc(at: [2]f64) -> Geo_Point {
	return {math.atan(math.sinh(math.PI * (1 - 2 * at.y))) * 180 / math.PI, at.x * 360 - 180}
}

// The world's width in pixels at a zoom level.
@(private = "file")
geo_world :: proc(zoom: int) -> f64 {
	return f64(GEO_TILE) * f64(u64(1) << uint(zoom))
}

// Longitude wraps around the world; latitude stops at its edges.
@(private = "file")
geo_settle :: proc(at: [2]f64) -> [2]f64 {
	return {at.x - math.floor(at.x), clamp(at.y, 0, 1)}
}

// ── fetch ───────────────────────────────────────────────────────────

// One HTTPS GET under the map user agent; nil on any failure.
@(private = "file")
geo_fetch :: proc(url, max_bytes: string) -> []u8 {
	state, data, stderr, err := tool_exec(
		{
			command = {
				curl_path(),
				"-sf",
				"--proto",
				"=https",
				"--user-agent",
				GEO_AGENT,
				"--max-time",
				"20",
				"--max-filesize",
				max_bytes,
				"--",
				url,
			},
		},
		context.allocator,
	)
	delete(stderr)
	if err != nil || state.exit_code != 0 {
		delete(data)
		return nil
	}
	return data
}

@(private = "file")
geo_tile_worker :: proc(key: Geo_Tile_Key) {
	context.allocator = reload_allocator()
	defer frame_wake()
	url := fmt.aprintf("https://tile.openstreetmap.org/%d/%d/%d.png", key[0], key[1], key[2])
	defer delete(url)
	// The file name is keyed: a plain hash of the URL would say which
	// places were looked at.
	name, named := vault_blob_name(url)
	path := fmt.tprintf("%s/tile-%s.bin", media_cache_dir(), name)
	data: []u8
	fresh := false
	if named {data, fresh = geo_disk_read(path)}
	if !fresh {
		if fetched := geo_fetch(url, "1048576"); fetched != nil {
			delete(data)
			data = fetched
			if named {geo_disk_write(path, data)}
		}
	}
	sync.lock(&geo_mutex)
	append(&geo_tile_fresh, struct {
		key:  Geo_Tile_Key,
		data: []u8,
	}{key, data})
	sync.unlock(&geo_mutex)
}

// The tile's current state, requesting it when no fetch has started
// and a slot is free. A tile waiting for a slot reports Loading.
@(private = "file")
geo_tile :: proc(key: Geo_Tile_Key) -> Geo_Tile {
	tile, seen := geo_tiles[key]
	if !seen {
		if geo_fetches >= GEO_FETCHES {return {}}
		geo_fetches += 1
		append(&send_threads, thread.create_and_start_with_poly_data(key, geo_tile_worker))
	}
	tile.used = geo_frame
	geo_tiles[key] = tile
	return tile
}

// A cached tile, and whether it is young enough to skip the network.
@(private = "file")
geo_disk_read :: proc(path: string) -> (data: []u8, fresh: bool) {
	sealed, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return}
	opened: bool
	data, opened = vault_open_blob(sealed)
	if !opened {return nil, false}
	info, stat_err := os.stat(path, context.temp_allocator)
	return data, stat_err == nil && time.since(info.modification_time) < GEO_TILE_TTL
}

// Seal a fetched tile into media-cache and keep the tiles' total under
// GEO_DISK_CAP. The total is summed once, then tracked per write.
@(private = "file")
geo_disk_write :: proc(path: string, data: []u8) {
	sealed, ok := vault_seal_blob(data, context.temp_allocator)
	if !ok {return}
	dir := media_cache_dir()
	sync.lock(&geo_disk_mutex)
	defer sync.unlock(&geo_disk_mutex)
	if geo_disk_bytes < 0 {geo_disk_bytes = geo_disk_trim(dir, GEO_DISK_CAP)}
	old: i64
	if info, err := os.stat(path, context.temp_allocator); err == nil {old = info.size}
	os.make_directory(dir)
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, sealed, {.Read_User, .Write_User}) != nil {return}
	if os.rename(tmp, path) != nil {os.remove(tmp); return}
	geo_disk_bytes += i64(len(sealed)) - old
	if geo_disk_bytes > GEO_DISK_CAP {geo_disk_bytes = geo_disk_trim(dir, GEO_DISK_KEEP)}
}

// Delete the oldest-fetched tile files in `dir` until they total at
// most `keep` bytes, and return what remains. Other cache files are
// never touched.
@(private)
geo_disk_trim :: proc(dir: string, keep: i64) -> i64 {
	files, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {return 0}
	tiles := make([dynamic]os.File_Info, context.temp_allocator)
	total: i64
	for file in files {
		if !strings.has_prefix(file.name, "tile-") ||
		   !strings.has_suffix(file.name, ".bin") {continue}
		append(&tiles, file)
		total += file.size
	}
	slice.sort_by(tiles[:], proc(a, b: os.File_Info) -> bool {
		return time.diff(a.modification_time, b.modification_time) > 0
	})
	for tile in tiles {
		if total <= keep {break}
		if os.remove(tile.fullpath) == nil {total -= tile.size}
	}
	return total
}

@(private = "file")
Geo_Place_Job :: struct {
	key, url: string, // key is the geo_places key; url owned
}

// Nominatim's usage policy allows one request per second, so lookups
// run one at a time and each holds its slot for at least that long.
@(private = "file")
geo_place_worker :: proc(job: Geo_Place_Job) {
	context.allocator = reload_allocator()
	defer frame_wake()
	start := time.tick_now()
	out := geo_fetch(job.url, "262144")
	delete(job.url)
	label := geo_place_parse(out)
	delete(out)
	time.sleep(max(0, time.Second - time.tick_since(start)))
	sync.lock(&geo_mutex)
	append(&geo_place_fresh, struct {
		key, label: string,
	}{job.key, label})
	sync.unlock(&geo_mutex)
}

// "Berlin, Germany" from a reverse lookup at city zoom, or "" for the
// open sea and errors.
@(private)
geo_place_parse :: proc(body: []u8) -> string {
	value, err := json.parse(body)
	if err != nil {return ""}
	defer json.destroy_value(value)
	root, _ := value.(json.Object)
	address, _ := root["address"].(json.Object)
	place: json.String
	for field in ([]string{"city", "town", "village", "hamlet", "municipality", "county", "state"}) {
		place, _ = address[field].(json.String)
		if len(place) > 0 {break}
	}
	country, _ := address["country"].(json.String)
	if len(place) > 0 && len(country) > 0 {return fmt.aprintf("%s, %s", place, country)}
	return strings.clone(len(place) > 0 ? string(place) : string(country))
}

// The place name for a pin, looked up once per session and language.
@(private = "file")
geo_place :: proc(pin: Geo_Point) -> string {
	if g_ui == nil || !g_ui.prefs.map_consent {return ""}
	lang := g_ui.prefs.locale
	// Three decimals (about 100 m) is plenty for a city name.
	key := fmt.tprintf("%.3f,%.3f,%s", pin.lat, pin.lon, lang)
	if label, seen := geo_places[key]; seen || geo_place_busy {return label}
	owned := strings.clone(key)
	geo_places[owned] = ""
	geo_place_busy = true
	url := fmt.aprintf(
		"https://nominatim.openstreetmap.org/reverse?format=jsonv2&zoom=10&lat=%.3f&lon=%.3f&accept-language=%s",
		pin.lat,
		pin.lon,
		lang,
	)
	append(
		&send_threads,
		thread.create_and_start_with_poly_data(Geo_Place_Job{owned, url}, geo_place_worker),
	)
	return ""
}

// Frame-loop drain: upload finished tiles, publish place names, and
// drop the least recently drawn tiles past the cap. It runs before the
// build, so no draw command still points at an unloaded texture.
@(private)
drain_geo :: proc() {
	geo_frame += 1
	sync.lock(&geo_mutex)
	for fresh in geo_tile_fresh {
		geo_fetches -= 1
		tile := Geo_Tile {
			state = .Failed,
			used  = geo_frame,
		}
		image := nev_image_decode(fresh.data)
		delete(fresh.data)
		if image.data != nil {
			tile.tex = new(rl.Texture2D)
			tile.tex^ = rl.LoadTextureFromImage(image)
			tile.state = .Ready
			rl.UnloadImage(image)
		}
		geo_tiles[fresh.key] = tile
	}
	clear(&geo_tile_fresh)
	for fresh in geo_place_fresh {
		geo_places[fresh.key] = fresh.label
		geo_place_busy = false
	}
	clear(&geo_place_fresh)
	sync.unlock(&geo_mutex)

	for len(geo_tiles) > GEO_TILE_CAP {
		oldest: Geo_Tile_Key
		oldest_used := max(u64)
		for key, tile in geo_tiles {
			if tile.state == .Loading || tile.used >= oldest_used {continue}
			oldest, oldest_used = key, tile.used
		}
		if oldest_used == max(u64) {break}
		if tex := geo_tiles[oldest].tex; tex != nil {
			rl.UnloadTexture(tex^)
			free(tex)
		}
		delete_key(&geo_tiles, oldest)
	}
}

// ── drawing ─────────────────────────────────────────────────────────

// The message whose body is being drawn (timeline.odin sets it), or ""
// outside the timeline. It keeps the same location shared twice from
// moving as one map.
@(private)
geo_owner: string

// A view per message and link. ponytail: one link repeated inside one
// message shares a view; add the card's position if that shows up.
@(private = "file")
geo_view_key :: proc(key: string) -> string {
	return fmt.tprintf("%s\x00%s", geo_owner, key)
}

// An interactive map of `w`x`h` centered on the pin. `key` (the link)
// names its view, which keeps pan and zoom across frames.
@(private)
geo_map :: proc(id: u32, key: string, pin: Geo_Point, zoom: int, w, h: f32) {
	if g_ui == nil || !g_ui.prefs.map_consent {
		if !geo_declined {geo_consent(id, w)}
		return
	}
	view_key := geo_view_key(key)
	view, seen := geo_views[view_key]
	if !seen {
		home := geo_project(pin)
		z := clamp(zoom, GEO_ZOOM_MIN, GEO_ZOOM_MAX)
		view = {
			key    = strings.clone(view_key),
			center = home,
			home   = home,
			zoom   = z,
			home_z = z,
		}
		geo_views[view.key] = view
	}

	// The tile grid under the map, and where its first tile sits:
	//
	//   (tx0, ty0) ┌──────┬──────┬──────┐
	//              │  ┌───┼──────┼──┐   │  the map is a window onto
	//              ├──┼───┼──────┼──┼───┤  cols x rows tiles, shifted
	//              │  └───┼──────┼──┘   │  by childOffset
	//              └──────┴──────┴──────┘
	world := geo_world(view.zoom)
	left := view.center.x * world - f64(w) / 2
	top := view.center.y * world - f64(h) / 2
	tx0 := int(math.floor(left / GEO_TILE))
	ty0 := int(math.floor(top / GEO_TILE))
	cols := int(math.floor((left + f64(w)) / GEO_TILE)) - tx0 + 1
	rows := int(math.floor((top + f64(h)) / GEO_TILE)) - ty0 + 1
	n := 1 << uint(view.zoom)

	// Only a map on screen requests tiles.
	box := clay.GetElementData(clay.ID("GeoMap", id))
	visible :=
		box.found &&
		box.boundingBox.y + box.boundingBox.height > 0 &&
		box.boundingBox.y < f32(rl.GetScreenHeight()) / UI_ZOOM

	wanted, loaded, failed := 0, 0, 0
	// Overlays attach to this frame, not to GeoMap: a floating element
	// clips to its parent's clip, and GeoMap's own clip would let it
	// paint over the header once the card scrolls under it.
	if clay.UI(clay.ID("GeoFrame", id))(
	{layout = {sizing = {width = clay.SizingFixed(w), height = clay.SizingFixed(h)}}},
	) {
		if clay.UI(clay.ID("GeoMap", id))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(w), height = clay.SizingFixed(h)},
				layoutDirection = .TopToBottom,
			},
			clip = {
				horizontal = true,
				vertical = true,
				childOffset = {f32(f64(tx0 * GEO_TILE) - left), f32(f64(ty0 * GEO_TILE) - top)},
			},
			backgroundColor = fade(TEXT_DIM, 0.12),
		},
		) {
			if clay.Hovered() {
				geo_hover, geo_hover_box = view.key, box.boundingBox
				cursor_raise(.Grabbing)
			}
			for r in 0 ..< rows {
				if clay.UI(clay.ID("GeoRow", id * 8 + u32(r)))({}) {
					for c in 0 ..< cols {
						ty := ty0 + r
						tile: Geo_Tile
						if visible && ty >= 0 && ty < n {
							wanted += 1
							tile = geo_tile(
								{i32(view.zoom), i32(((tx0 + c) % n + n) % n), i32(ty)},
							)
							if tile.state == .Ready {loaded += 1}
							if tile.state == .Failed {failed += 1}
						}
						if clay.UI(clay.ID("GeoTile", id * 32 + u32(r * cols + c)))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(GEO_TILE),
									height = clay.SizingFixed(GEO_TILE),
								},
							},
							image = {imageData = tile.tex},
						},
						) {}
					}
				}
			}
		}
		geo_pin(id, view, pin, w, h)
		geo_controls(id, view)
		geo_map_status(id, wanted, loaded, failed)
		if clay.UI(clay.ID("GeoCredit", id))(
		{
			layout = {padding = {left = 6, right = 6, top = 2, bottom = 2}},
			floating = {
				attachTo = .Parent,
				clipTo = .AttachedParent,
				attachment = {element = .RightBottom, parent = .RightBottom},
			},
			backgroundColor = fade(PLATE, 0.85),
		},
		) {
			if hovered() {link_hover = "https://www.openstreetmap.org/copyright"}
			clay.Text(
				tr("© OpenStreetMap contributors"),
				{fontId = FONT_BODY, fontSize = 10, textColor = TEXT},
			)
		}
	}
}

// First-use disclosure drawn where the map would be. Nothing loads
// until Accept; Not now hides maps for the session.
@(private = "file")
geo_consent :: proc(id: u32, w: f32) {
	if clay.UI(clay.ID("GeoConsent", id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(w)},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(14),
			childGap = 10,
		},
		backgroundColor = ROW_BG,
		cornerRadius = rr(8),
	},
	) {
		clay.Text(
			tr("Show maps from OpenStreetMap?"),
			{fontId = FONT_TITLE, fontSize = 15, textColor = TEXT},
		)
		clay.Text(tr(GEO_DISCLOSURE), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
		clay.Text(
			tr("Nothing loads until you accept. You can change this in Settings > Advanced."),
			{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
		)
		if clay.UI(clay.ID("GeoConsentRow", id))(
		{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8, padding = {top = 4}}},
		) {
			if clay.UI(clay.ID("GeoConsentGap", id))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			buttons := [?]struct {
				action: Geo_Action,
				label:  string,
			}{{.Decline, tr("Not now")}, {.Accept, tr("Accept")}}
			for button, i in buttons {
				if clay.UI(clay.ID("GeoConsentButton", id * 2 + u32(i)))(
				{
					layout = {padding = {left = 14, right = 14, top = 7, bottom = 7}},
					backgroundColor = hovered() ? ACCENT : PLATE,
					cornerRadius = rr(7),
					border = {color = CARD_BORDER, width = bw()},
				},
				) {
					if hovered() {geo_action = button.action}
					clay.Text(
						button.label,
						{
							fontId = FONT_BODY,
							fontSize = 13,
							textColor = hovered() ? ink_on(ACCENT) : TEXT,
						},
					)
				}
			}
		}
	}
}

// The pin, centered on the exact point: an accent dot in a white ring
// and a soft shadow, inside an accent halo. The ring and shadow are
// fixed because OSM tiles keep their own light palette under every
// theme. The pin floats over the frame, which does not clip, so it
// hides before it would cross the map's edge.
@(private = "file")
geo_pin :: proc(id: u32, view: Geo_View, pin: Geo_Point, w, h: f32) {
	HALO :: 36
	at := geo_project(pin) - view.center
	at.x -= math.round(at.x) // the nearer copy across the antimeridian
	world := geo_world(view.zoom)
	x := f64(w) / 2 + at.x * world
	y := f64(h) / 2 + at.y * world
	if x < HALO / 2 || x > f64(w) - HALO / 2 || y < HALO / 2 || y > f64(h) - HALO / 2 {return}
	if clay.UI(clay.ID("GeoPin", id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(HALO), height = clay.SizingFixed(HALO)},
			childAlignment = {x = .Center, y = .Center},
		},
		floating = {
			attachTo = .Parent,
			clipTo = .AttachedParent,
			pointerCaptureMode = .Passthrough,
			offset = {f32(x), f32(y)},
			attachment = {element = .CenterCenter, parent = .LeftTop},
		},
		backgroundColor = fade(ACCENT, 0.3),
		cornerRadius = clay.CornerRadiusAll(HALO / 2),
	},
	) {
		if clay.UI(clay.ID("GeoPinShadow", id))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(22), height = clay.SizingFixed(22)},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = {0, 0, 0, 110},
			cornerRadius = clay.CornerRadiusAll(11),
		},
		) {
			if clay.UI(clay.ID("GeoPinDot", id))(
			{
				layout = {sizing = {width = clay.SizingFixed(18), height = clay.SizingFixed(18)}},
				backgroundColor = ACCENT,
				cornerRadius = clay.CornerRadiusAll(9),
				border = {color = {255, 255, 255, 255}, width = {3, 3, 3, 3, 0}},
			},
			) {}
		}
	}
}

// Zoom in, zoom out, and Recenter once the view has left the pin.
@(private = "file")
geo_controls :: proc(id: u32, view: Geo_View) {
	if clay.UI(clay.ID("GeoControls", id))(
	{
		layout = {layoutDirection = .TopToBottom, childGap = 4},
		floating = {
			attachTo = .Parent,
			clipTo = .AttachedParent,
			offset = {-8, 8},
			attachment = {element = .RightTop, parent = .RightTop},
		},
	},
	) {
		buttons := [?]struct {
			action:     Geo_Action,
			glyph, tip: string,
			font:       u16,
		} {
			{.Zoom_In, "+", tr("Zoom in"), FONT_TITLE},
			{.Zoom_Out, "−", tr("Zoom out"), FONT_TITLE},
			{.Recenter, "\uf05b", tr("Recenter"), FONT_ICON},
		}
		moved := view.center != view.home || view.zoom != view.home_z
		for button, i in buttons {
			if button.action == .Recenter && !moved {continue}
			if clay.UI(clay.ID("GeoButton", id * 4 + u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(28), height = clay.SizingFixed(28)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = hovered() ? HOVER : fade(PLATE, 0.92),
				cornerRadius = rr(6),
				border = {color = CARD_BORDER, width = bw()},
			},
			) {
				if hovered() {
					geo_action, geo_action_key = button.action, view.key
					tooltip(button.tip, .Right)
				}
				clay.Text(button.glyph, {fontId = button.font, fontSize = 16, textColor = TEXT})
			}
		}
	}
}

// Tiles still arriving show measured progress; misses offer a retry.
@(private = "file")
geo_map_status :: proc(id: u32, wanted, loaded, failed: int) {
	if loaded == wanted {return}
	TRACK :: 72
	if clay.UI(clay.ID("GeoStatus", id))(
	{
		layout = {
			padding = {left = 8, right = 8, top = 5, bottom = 5},
			childGap = 8,
			childAlignment = {y = .Center},
		},
		floating = {
			attachTo = .Parent,
			clipTo = .AttachedParent,
			offset = {8, -8},
			attachment = {element = .LeftBottom, parent = .LeftBottom},
		},
		backgroundColor = failed > 0 && hovered() ? HOVER : fade(PLATE, 0.92),
		cornerRadius = rr(6),
	},
	) {
		if failed > 0 && loaded + failed == wanted {
			if hovered() {geo_action = .Retry}
			clay.Text(
				tr("Couldn't load the map. Please try again."),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT},
			)
			clay.Text(tr("Retry"), {fontId = FONT_TITLE, fontSize = 11, textColor = ACCENT})
			return
		}
		clay.Text(tr("Loading map"), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT})
		if clay.UI(clay.ID("GeoTrack", id))(
		{
			layout = {sizing = {clay.SizingFixed(TRACK), clay.SizingFixed(4)}},
			backgroundColor = ROW_BG,
			cornerRadius = rr(2),
		},
		) {
			if clay.UI(clay.ID("GeoFill", id))(
			{
				layout = {
					sizing = {
						clay.SizingFixed(TRACK * f32(loaded + failed) / f32(max(wanted, 1))),
						clay.SizingFixed(4),
					},
				},
				backgroundColor = ACCENT,
				cornerRadius = rr(2),
			},
			) {}
		}
	}
}

// "38.89768° N, 116.05997° W"
@(private = "file")
geo_format :: proc(pin: Geo_Point) -> string {
	return fmt.tprintf(
		"%.5f° %s, %.5f° %s",
		abs(pin.lat),
		pin.lat < 0 ? "S" : "N",
		abs(pin.lon),
		pin.lon < 0 ? "W" : "E",
	)
}

// The user's map site and its "Open in" label. OpenStreetMap opens on
// the view the map shows (the pin before there is a map); the others
// open on the pin.
@(private)
geo_open :: proc(key: string, pin: Geo_Point, zoom: int) -> (url, label: string) {
	browser := g_ui != nil ? g_ui.prefs.map_browser : .OpenStreetMap
	label = tr(MAP_BROWSER_OPEN[browser])
	switch browser {
	case .OpenStreetMap:
		view, seen := geo_views[geo_view_key(key)]
		if !seen {view = {
				center = geo_project(pin),
				zoom   = zoom,
			}}
		center := geo_unproject(view.center)
		url = fmt.tprintf(
			"https://www.openstreetmap.org/?mlat=%.6f&mlon=%.6f#map=%d/%.5f/%.5f",
			pin.lat,
			pin.lon,
			view.zoom,
			center.lat,
			center.lon,
		)
	case .Apple_Maps:
		url = fmt.tprintf("https://maps.apple.com/place?coordinate=%.6f%%2C%.6f", pin.lat, pin.lon)
	case .Kagi_Maps:
		url = fmt.tprintf("https://kagi.com/maps/pins/%.6f,%.6f", pin.lat, pin.lon)
	case .Google_Maps:
		url = fmt.tprintf(
			"https://www.google.com/maps/search/?api=1&query=%.6f%%2C%.6f",
			pin.lat,
			pin.lon,
		)
	}
	return
}

// A location link drawn in place of its URL.
@(private)
geo_card :: proc(id: u32, url: string, link: Geo_Link) {
	pin := link.pin
	zoom := link.zoom > 0 ? link.zoom : GEO_ZOOM_SHARE
	w := att_w(400)
	if clay.UI(clay.ID("GeoCard", id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(w)},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(6),
			childGap = 10,
		},
		backgroundColor = PLATE,
		cornerRadius = rr(12),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		geo_map(id, url, pin, zoom, w - 12, GEO_MAP_H)
		if clay.UI(clay.ID("GeoInfo", id))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				childGap = 4,
				padding = {left = 8, right = 8, bottom = 6},
			},
		},
		) {
			clay.Text(
				tr("LOCATION"),
				{fontId = FONT_BODY, fontSize = 9, textColor = TEXT_DIM, letterSpacing = 1},
			)
			place := geo_place(pin)
			clay.Text(
				len(place) > 0 ? place : tr("Shared location"),
				{fontId = FONT_TITLE, fontSize = 15, textColor = TEXT},
			)
			clay.Text(geo_format(pin), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
			open_url, open_label := geo_open(url, pin, zoom)
			if clay.UI(clay.ID("GeoActions", id))(
			{layout = {childGap = 14, padding = {top = 4}}},
			) {
				if clay.UI(clay.ID("GeoCopy", id))({}) {
					if hovered() {geo_action, geo_action_pin = .Copy, pin}
					clay.Text(
						tr("Copy coordinates"),
						{fontId = FONT_BODY, fontSize = 12, textColor = ACCENT},
					)
				}
				if clay.UI(clay.ID("GeoOpen", id))({}) {
					if hovered() {link_hover = open_url}
					clay.Text(open_label, {fontId = FONT_BODY, fontSize = 12, textColor = ACCENT})
				}
			}
		}
	}
}

// ── input ───────────────────────────────────────────────────────────

// Drag pans, the wheel zooms about the pointer, and the buttons act on
// release. Runs after layout; the frame loop zeroes the timeline's
// wheel while a map is hovered so zooming doesn't also scroll.
@(private)
handle_geo :: proc(ui: ^Ui_State) {
	// Logical pixels; devctl's pointer when it holds one.
	mouse := test_pointer_on ? test_pointer : transmute([2]f32)rl.GetMousePosition()
	mouse /= UI_ZOOM
	if mouse_pressed() && geo_drag == "" && geo_hover != "" && geo_action == .None {
		geo_drag, geo_grab = geo_hover, mouse
	}
	if geo_drag != "" {
		view, ok := &geo_views[geo_drag]
		if !ok || !rl.IsMouseButtonDown(.LEFT) {
			geo_drag = ""
		} else {
			step := [2]f64{f64(mouse.x - geo_grab.x), f64(mouse.y - geo_grab.y)}
			view.center = geo_settle(view.center - step / geo_world(view.zoom))
			geo_grab = mouse
		}
	}

	if view, ok := &geo_views[geo_hover]; ok {
		view.wheel += rl.GetMouseWheelMoveV().y
		box := geo_hover_box
		at := [2]f64{f64(mouse.x - box.x - box.width / 2), f64(mouse.y - box.y - box.height / 2)}
		for abs(view.wheel) >= 1 {
			step := view.wheel > 0 ? 1 : -1
			view.wheel -= f32(step)
			geo_zoom(view, step, at)
		}
	}

	if !mouse_released() || modal_open(ui) {return}
	switch geo_action {
	case .None:
	case .Zoom_In, .Zoom_Out:
		if view, ok := &geo_views[geo_action_key]; ok {
			geo_zoom(view, geo_action == .Zoom_In ? 1 : -1, {})
		}
	case .Recenter:
		if view, ok := &geo_views[geo_action_key]; ok {
			view.center, view.zoom = view.home, view.home_z
		}
	case .Retry:
		missed := make([dynamic]Geo_Tile_Key, context.temp_allocator)
		for key, tile in geo_tiles {
			if tile.state == .Failed {append(&missed, key)}
		}
		for key in missed {delete_key(&geo_tiles, key)}
	case .Copy:
		copy_text(
			ui,
			fmt.tprintf("%.6f, %.6f", geo_action_pin.lat, geo_action_pin.lon),
			tr("Copied"),
		)
	case .Accept, .Decline:
		if geo_action == .Accept {
			ui.prefs.map_consent = true
			save_settings(ui)
		} else {
			geo_declined = true
		}
		// The panel, the map and neither differ in height.
		for &msg in ui.messages {msg.row_height = 0}
	}
}

// One zoom step, holding still the point `at` pixels from the center:
// it sits at center + at/world before and after.
@(private = "file")
geo_zoom :: proc(view: ^Geo_View, step: int, at: [2]f64) {
	zoom := clamp(view.zoom + step, GEO_ZOOM_MIN, GEO_ZOOM_MAX)
	if zoom == view.zoom {return}
	point := view.center + at / geo_world(view.zoom)
	view.center = geo_settle(point - at / geo_world(zoom))
	view.zoom = zoom
}
