// Starter identity for freshly generated accounts: a deterministic
// "[Adjective] [Animal]" name from the new npub, offered as the name
// the user is asked for, plus a composed face (emoji animal glyph over
// the npub gradient) uploaded to Blossom for its kind-0 picture.
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:slice"
import "core:strings"

import stbi "vendor:stb/image"

import marmot "../marmot"
import rl "sdlrl"

@(private = "file")
ADJECTIVES := [?]string {
	"Spooky",
	"Cosmic",
	"Dapper",
	"Fuzzy",
	"Sleepy",
	"Sneaky",
	"Mighty",
	"Velvet",
	"Turbo",
	"Witty",
	"Zesty",
	"Plucky",
	"Quirky",
	"Nimble",
	"Frosty",
	"Mellow",
	"Peppy",
	"Rusty",
	"Stormy",
	"Sunny",
	"Dusty",
	"Misty",
	"Jolly",
	"Groovy",
	"Snazzy",
	"Breezy",
	"Cheeky",
	"Daring",
	"Electric",
	"Golden",
	"Icy",
	"Lucky",
	"Magnetic",
	"Neon",
	"Prickly",
	"Quantum",
	"Silent",
	"Vivid",
	"Wandering",
	"Wobbly",
}

// Every animal pairs its name with the emoji codepoint used for the
// face, so any generated name is guaranteed to have art on disk.
Starter_Animal :: struct {
	name: string,
	cp:   rune,
}

ANIMALS := [?]Starter_Animal {
	{"Bear", '🐻'},
	{"Fox", '🦊'},
	{"Otter", '🦦'},
	{"Wolf", '🐺'},
	{"Owl", '🦉'},
	{"Badger", '🦡'},
	{"Panda", '🐼'},
	{"Koala", '🐨'},
	{"Hedgehog", '🦔'},
	{"Raccoon", '🦝'},
	{"Penguin", '🐧'},
	{"Toad", '🐸'},
	{"Hare", '🐰'},
	{"Falcon", '🦅'},
	{"Parrot", '🦜'},
	{"Gecko", '🦎'},
	{"Beaver", '🦫'},
	{"Seal", '🦭'},
	{"Bison", '🦬'},
	{"Lion", '🦁'},
	{"Tiger", '🐯'},
	{"Deer", '🦌'},
	{"Duck", '🦆'},
	{"Llama", '🦙'},
}

// Output edge; big enough that the 72px emoji tile upscales cleanly
// for every avatar size the UI renders.
@(private = "file")
STARTER_SIDE :: 256

// Deterministic "[Adjective] [Animal]" pick from the npub hash, so the
// same key always regenerates the same identity.
starter_identity :: proc(npub: string) -> (name: string, cp: rune) {
	h := avatar_hash(npub)
	animal := ANIMALS[(h >> 16) % len(ANIMALS)]
	return fmt.tprintf("%s %s", ADJECTIVES[h % len(ADJECTIVES)], animal.name), animal.cp
}

// The face: vertical npub gradient with the animal glyph bilinearly
// upscaled and alpha-blended over it. data == nil when the tile is
// missing (temp-allocated otherwise; texture upload copies it).
@(private = "file")
starter_face :: proc(npub: string, cp: rune) -> rl.Image {
	glyph := emoji_image(fmt.tprintf("%c", cp))
	if glyph.data == nil {
		return {}
	}
	defer rl.UnloadImage(glyph)

	// Gradient: the row-avatar hue on top fading to a darker shade.
	hue := f32(avatar_hash(npub) % 360)
	top := hsv(hue, 0.45, 0.62)
	bottom := hsv(hue, 0.55, 0.32)
	out := make([]u8, STARTER_SIDE * STARTER_SIDE * 4, context.temp_allocator)
	for y in 0 ..< STARTER_SIDE {
		t := f32(y) / f32(STARTER_SIDE - 1)
		r := u8(top.r + (bottom.r - top.r) * t)
		g := u8(top.g + (bottom.g - top.g) * t)
		b := u8(top.b + (bottom.b - top.b) * t)
		for x in 0 ..< STARTER_SIDE {
			d := (y * STARTER_SIDE + x) * 4
			out[d + 0], out[d + 1], out[d + 2], out[d + 3] = r, g, b, 255
		}
	}

	// Glyph centered at ~66% of the canvas.
	face := STARTER_SIDE * 2 / 3
	off := (STARTER_SIDE - face) / 2
	blend_tile(out, STARTER_SIDE, glyph, {off, off}, face)
	return {data = raw_data(out), width = STARTER_SIDE, height = STARTER_SIDE}
}

// PNG-encode an RGBA image via stb, collecting the writer callbacks
// into one buffer.
@(private = "file")
png_buf: [dynamic]u8

@(private = "file")
png_sink :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
	context = (cast(^runtime.Context)ctx)^
	append(&png_buf, ..slice.bytes_from_ptr(data, int(size)))
}

@(private = "file")
image_png :: proc(image: rl.Image) -> []u8 {
	clear(&png_buf)
	ctx := context
	stbi.write_png_to_func(
		png_sink,
		&ctx,
		image.width,
		image.height,
		4,
		image.data,
		image.width * 4,
	)
	return png_buf[:]
}

// The account's npub, or "" when it can't be read.
@(private = "file")
account_npub :: proc(client: ^marmot.Client, hex: string) -> string {
	npub_c: cstring
	if marmot.npub(client, strings.clone_to_cstring(hex, context.temp_allocator), &npub_c) !=
		   .OK ||
	   npub_c == nil {
		return ""
	}
	defer marmot.string_free(npub_c)
	return strings.clone(string(npub_c), context.temp_allocator)
}

// Upload a freshly generated account's face to public Blossom so its
// kind-0 can carry the URL; peers and future sessions then fetch it like
// any picture. Blocks on the upload, so it runs on the sign-in worker;
// the URL is cloned into `allocator` for the UI thread to adopt. A
// failure only logs, and an empty URL still leaves a local face.
upload_starter_face :: proc(
	client: ^marmot.Client,
	hex: string,
	allocator := context.allocator,
) -> string {
	npub := account_npub(client, hex)
	if len(npub) == 0 {
		return ""
	}
	_, cp := starter_identity(npub)
	face := starter_face(npub, cp)
	if face.data == nil {
		return ""
	}

	png := image_png(face)
	url_c: cstring
	if len(png) == 0 ||
	   marmot.upload_profile_image(
		   client,
		   strings.clone_to_cstring(hex, context.temp_allocator),
		   raw_data(png),
		   uint(len(png)),
		   "image/png",
		   nil,
		   &url_c,
	   ) !=
		   .OK ||
	   url_c == nil {
		fmt.eprintfln("starter: couldn't upload the face: %s", marmot.last_error())
		return ""
	}
	defer marmot.string_free(url_c)
	return strings.clone(string(url_c), allocator)
}

// Publish the name the user chose for a fresh account, with its face
// URL, as the account's kind-0. Blocks on the relay round trip, so it
// runs on the sign-in worker. Returns "" once published, else the error
// with marmot's thread-local detail, cloned into `allocator`.
publish_starter_name :: proc(
	client: ^marmot.Client,
	hex, name, pic_url: string,
	allocator := context.allocator,
) -> string {
	name_c := strings.clone_to_cstring(name, context.temp_allocator)
	metadata := marmot.User_Profile_Metadata {
		name         = name_c,
		display_name = name_c,
		picture      = pic_url != "" ? strings.clone_to_cstring(pic_url, context.temp_allocator) : nil,
	}
	out: ^marmot.User_Profile_Metadata
	if marmot.publish_user_profile(
		   client,
		   strings.clone_to_cstring(hex, context.temp_allocator),
		   &metadata,
		   raw_data(DEFAULT_RELAYS),
		   uint(len(DEFAULT_RELAYS)),
		   raw_data(DEFAULT_RELAYS),
		   uint(len(DEFAULT_RELAYS)),
		   &out,
	   ) !=
	   .OK {
		return fmt.aprintf(
			tr("Couldn't publish your name. %s"),
			marmot.last_error(),
			allocator = allocator,
		)
	}
	marmot.user_profile_metadata_free(out)
	return ""
}

// The local half of the seed: recompose the face and register it, with
// the chosen name, under its Blossom URL (or a starter:// pseudo-URL
// when the upload failed). Texture creation, so this stays on the
// render thread.
seed_starter_local :: proc(client: ^marmot.Client, hex, name, pic_url: string) {
	npub := account_npub(client, hex)
	if len(npub) == 0 {
		return
	}
	_, cp := starter_identity(npub)
	register_starter_pic(
		hex,
		name,
		pic_url != "" ? pic_url : fmt.tprintf("starter://%s", hex),
		starter_face(npub, cp),
	)
}

// Regenerate the local starter face at login. The face never leaves
// this device (kind-0 has no picture URL), so an account whose
// published name still matches its deterministic starter name gets
// the same face composed again from the npub.
restore_starter_pic :: proc(ui: ^Ui_State, client: ^marmot.Client, hex: string) {
	if len(profile_info(client, hex).pic_url) > 0 {
		return
	}

	account := strings.clone_to_cstring(hex, context.temp_allocator)
	npub_c: cstring
	if marmot.npub(client, account, &npub_c) != .OK || npub_c == nil {
		return
	}
	npub := strings.clone(string(npub_c), context.temp_allocator)
	marmot.string_free(npub_c)

	name, cp := starter_identity(npub)
	if name != profile_info(client, hex).name {
		return
	}
	register_starter_pic(hex, name, fmt.tprintf("starter://%s", hex), starter_face(npub, cp))
}
