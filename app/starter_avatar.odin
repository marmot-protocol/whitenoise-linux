// Starter names and pictures derive from the account's public key.
package main

import "base:runtime"
import "core:c"
import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

import stbi "vendor:stb/image"

import marmot "../marmot"
import rl "sdlrl"

@(private)
STARTER_BLOSSOM :: cstring("https://blossom.primal.net")

// The same pinned secp256k1 library that verifies Nostr events for sticker packs.
@(private = "file", default_calling_convention = "c", link_prefix = "rustsecp256k1_v0_10_0_")
foreign _ {
	context_create :: proc(flags: c.uint) -> rawptr ---
	context_destroy :: proc(ctx: rawptr) ---
	context_randomize :: proc(ctx: rawptr, seed: ^[32]u8) -> c.int ---
	ec_pubkey_create :: proc(ctx: rawptr, pk: ^[64]u8, sk: ^[32]u8) -> c.int ---
	ec_pubkey_serialize :: proc(ctx: rawptr, out: ^[33]u8, len: ^c.size_t, pk: ^[64]u8, flags: c.uint) -> c.int ---
}

@(private = "file")
starter_key :: proc() -> (nsec, npub, public_hex: string) {
	CONTEXT_NONE :: c.uint(1 << 0)
	EC_COMPRESSED :: c.uint((1 << 1) | (1 << 8))
	ctx := context_create(CONTEXT_NONE)
	if ctx == nil {return "", "", ""}
	defer context_destroy(ctx)
	secret: [32]u8
	defer crypto.zero_explicit(&secret, len(secret))
	crypto.rand_bytes(secret[:])
	if context_randomize(ctx, &secret) != 1 {return "", "", ""}
	pub: [64]u8
	for {
		crypto.rand_bytes(secret[:])
		if ec_pubkey_create(ctx, &pub, &secret) == 1 {break}
	}
	encoded: [33]u8
	size := c.size_t(len(encoded))
	if ec_pubkey_serialize(ctx, &encoded, &size, &pub, EC_COMPRESSED) != 1 {
		return "", "", ""
	}
	// Nostr uses only the x coordinate.
	npub = bech32_encode("npub", encoded[1:])
	public_hex = string(hex.encode(encoded[1:]))
	// Keep the encoder's intermediate secret copies in wipeable scratch space.
	scratch: [2048]u8
	defer crypto.zero_explicit(&scratch, len(scratch))
	arena: mem.Arena
	mem.arena_init(&arena, scratch[:])
	context.temp_allocator = mem.arena_allocator(&arena)
	nsec = bech32_encode("nsec", secret[:])
	return nsec, npub, public_hex
}

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
// missing. Texture upload copies the pixels.
@(private = "file")
starter_face :: proc(npub: string, cp: rune, allocator := context.temp_allocator) -> rl.Image {
	glyph := emoji_image(fmt.tprintf("%c", cp))
	if glyph.data == nil {
		return {}
	}
	defer rl.UnloadImage(glyph)

	// Gradient: the row-avatar hue on top fading to a darker shade.
	hue := f32(avatar_hash(npub) % 360)
	top := hsv(hue, 0.45, 0.62)
	bottom := hsv(hue, 0.55, 0.32)
	out := make([]u8, STARTER_SIDE * STARTER_SIDE * 4, allocator)
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

@(private = "file")
Png_Write :: struct {
	ctx:   runtime.Context,
	bytes: [dynamic]u8,
}

@(private = "file")
png_sink :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
	write := (^Png_Write)(ctx)
	context = write.ctx
	append(&write.bytes, ..slice.bytes_from_ptr(data, int(size)))
}

@(private = "file")
image_png :: proc(image: rl.Image) -> []u8 {
	write := Png_Write{context, make([dynamic]u8, context.temp_allocator)}
	if stbi.write_png_to_func(
		   png_sink,
		   &write,
		   image.width,
		   image.height,
		   4,
		   image.data,
		   image.width * 4,
	   ) ==
	   0 {return nil}
	return write.bytes[:]
}

@(private = "file")
upload_starter_face :: proc(client: ^marmot.Client, hex: string, face: rl.Image) -> string {
	png := image_png(face)
	if len(png) == 0 {return ""}
	url_c: cstring
	if marmot.upload_profile_image(
		   client,
		   strings.clone_to_cstring(hex, context.temp_allocator),
		   raw_data(png),
		   uint(len(png)),
		   "image/png",
		   STARTER_BLOSSOM,
		   &url_c,
	   ) !=
	   .OK {
		detail := marmot.last_error()
		defer delete(detail)
		fmt.eprintfln("starter: couldn't upload the picture: %s", detail)
		return ""
	}
	defer marmot.string_free(url_c)
	return strings.clone(string(url_c))
}

@(private = "file")
publish_starter_name :: proc(client: ^marmot.Client, hex, name, pic_url: string) -> bool {
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
		detail := marmot.last_error()
		defer delete(detail)
		fmt.eprintfln("starter: profile publication not confirmed: %s", detail)
		return false
	}
	marmot.user_profile_metadata_free(out)
	return true
}

@(private)
prepare_starter :: proc(job: ^Auth_Job) {
	nsec, npub, public_hex := starter_key()
	defer delete(npub)
	job.nsec, job.hex = nsec, public_hex
	if npub != "" {
		name, cp := starter_identity(npub)
		job.name = strings.clone(name)
		job.starter_image = starter_face(npub, cp, context.allocator)
		if job.starter_image.data != nil {return}
	}
	job.err = strings.clone(tr("Couldn't prepare your starter profile. Please try again."))
}

@(private)
create_starter :: proc(job: ^Auth_Job) {
	hex, status, detail := import_identity_blocking(job.client, job.nsec, DEFAULT_RELAYS)
	defer delete(detail)
	if status != .OK {
		fmt.eprintfln("starter: couldn't finish account setup: %s", detail)
		job.err = strings.clone(tr("Couldn't finish account setup. Please try again."))
		// MDK can retain a local account after a relay error. Keep the exact
		// key for retry and only report a save after observing it.
		accounts: ^marmot.Account_Summary_List
		if marmot.list_accounts(job.client, &accounts) == .OK && accounts != nil {
			defer marmot.account_summary_list_free(accounts)
			for row in accounts.items[:accounts.len] {
				if string(row.account_id_hex) == job.hex {job.starter_saved = true; break}
			}
		}
		return
	}
	session_string_forget(&job.nsec)
	delete(job.hex)
	job.hex = hex
	job.pic_url = upload_starter_face(job.client, hex, job.starter_image)
	job.profile_confirmed = publish_starter_name(job.client, hex, job.name, job.pic_url)
}

@(private)
finish_starter :: proc(ui: ^Ui_State, job: ^Auth_Job) {
	register_starter_pic(
		job.hex,
		job.name,
		job.pic_url != "" ? job.pic_url : fmt.tprintf("starter://%s", job.hex),
		job.starter_image,
	)
	finish_auth(ui, job.client, job.hex)
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
