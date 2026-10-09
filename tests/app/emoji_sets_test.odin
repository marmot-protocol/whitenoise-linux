package main

import "base:runtime"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:sync"
import "core:testing"
import rl "sdlrl"

// The signer is the same linked secp256k1 fixture used by sticker_test.odin.
@(private)
emoji_test_event :: proc(identifier, title: string, at: u64 = 123) -> Sticker_Event {
	event := Sticker_Event {
		pubkey     = "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9",
		kind       = EMOJI_SET_KIND,
		created_at = at,
		tags       = {
			{"d", identifier},
			{"title", title},
			{"description", "A signed collection"},
			{"emoji", "happy-fox", "https://example.com/fox"},
			{"emoji", "happy-fox", "https://example.com/ignored"},
			{"emoji", "second", "https://example.com/second"},
			{"emoji", "../escape", "https://example.com/escape"},
			{"emoji", "insecure", "http://example.com/insecure"},
		},
	}
	tags, _ := json.marshal(event.tags, allocator = context.temp_allocator)
	canonical := fmt.tprintf(`[0,"%s",%d,30030,%s,""]`, event.pubkey, at, string(tags))
	digest := hash.hash_bytes(.SHA256, transmute([]u8)canonical, context.temp_allocator)
	event.id = string(hex.encode(digest, context.temp_allocator))
	secret: [32]u8; secret[31] = 3
	pair: [96]u8; signature: [64]u8
	ctx := context_create(1); defer context_destroy(ctx)
	assert(keypair_create(ctx, &pair, raw_data(secret[:])) == 1)
	assert(schnorrsig_sign32(ctx, &signature, raw_data(digest), &pair, nil) == 1)
	event.sig = string(hex.encode(signature[:], context.temp_allocator))
	return emoji_event_clone(event)
}

@(test)
emoji_set_validation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for code in ([]string{"happy-fox", "UPPER_01", "0", "-"}) {testing.expect(t, emoji_set_code_ok(code))}
	for code in ([]string{"", "../bad", "a/b", "a\\b", ".", "a.b", "a:b", "a b", "café"}) {testing.expect(t, !emoji_set_code_ok(code))}
	testing.expect(t, emoji_set_filename_ok("happy-fox.gif", "happy-fox"))
	for path in ([]string{"../happy-fox.png", "/happy-fox.png", "happy-fox.png/extra", "happy-fox.svg", "happy-fox.png.next"}) {testing.expect(t, !emoji_set_filename_ok(path, "happy-fox"))}
	event := emoji_test_event("../../not-a-path", "Foxes")
	testing.expect(t, sticker_event_valid(event))
	set, ok := emoji_set_parse(event, "wss://example.com")
	testing.expect(t, ok)
	testing.expect_value(t, set.title, "Foxes")
	testing.expect_value(t, set.author, event.pubkey)
	testing.expect_value(t, set.coordinate, fmt.tprintf("30030:%s:../../not-a-path", event.pubkey))
	testing.expect_value(t, len(set.items), 2)
	testing.expect_value(t, set.items[0].code, "happy-fox")
	testing.expect_value(t, set.items[0].url, "https://example.com/fox")
	emoji_set_free(set)
	fallback, valid := emoji_set_parse(emoji_test_event("fallback", ""), "")
	testing.expect(t, valid); testing.expect_value(t, fallback.title, "fallback")
	emoji_set_free(fallback)
	event.tags[1][1] = "Forged"
	testing.expect(t, !sticker_event_valid(event), "signature protects set attribution")
	old, _ := emoji_set_parse(emoji_test_event("replaceable", "Old", 1), "wss://old")
	latest, _ := emoji_set_parse(emoji_test_event("replaceable", "New", 2), "wss://new")
	sets: [dynamic]Nostr_Emoji_Set
	defer {for row in sets {emoji_set_free(row)}; delete(sets)}
	emoji_set_merge(&sets, old); emoji_set_merge(&sets, latest)
	testing.expect_value(t, len(sets), 1)
	testing.expect_value(t, sets[0].title, "New")
	older_again, _ := emoji_set_parse(emoji_test_event("replaceable", "Old", 1), "wss://other")
	emoji_set_merge(&sets, older_again)
	testing.expect_value(t, sets[0].relay, "wss://new")
	// Same timestamp: lower event ID wins regardless of delivery order.
	a, _ := emoji_set_parse(emoji_test_event("tie", "A", 3), "")
	b, _ := emoji_set_parse(emoji_test_event("tie", "B", 3), "")
	wanted := a.event < b.event ? a.title : b.title
	emoji_set_merge(&sets, b); emoji_set_merge(&sets, a)
	testing.expect_value(t, sets[1].title, wanted)
}

@(test)
emoji_set_persistence :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock); defer sync.unlock(&test_home_lock)
	directory, err := os.make_directory_temp("/tmp", "wn-emoji-set-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(directory)
	event := emoji_test_event("../../outside", "Woodland")
	defer emoji_event_free(event)
	set, valid := emoji_set_parse(event, "wss://example.com")
	if !testing.expect(t, valid) {return}
	defer emoji_set_free(set)
	bytes := BUILTIN_EMOJI[0].png
	image, ext := emoji_asset_image(bytes)
	testing.expect(t, image.data != nil)
	testing.expect_value(t, ext, ".png")
	if image.data != nil {rl.UnloadImage(image)}
	rejected, _ := emoji_asset_image(transmute([]u8)string("not an image at all"))
	testing.expect(t, rejected.data == nil)
	testing.expect(t, emoji_import_asset(directory, set, set.items[0], bytes, ".png"))
	testing.expect(
		t,
		!emoji_import_asset(
			directory,
			set,
			set.items[0],
			transmute([]u8)string("replacement"),
			".png",
		),
		"an imported image is immutable",
	)
	path := fmt.tprintf("%s/sets/%s/happy-fox.png", directory, event.id)
	saved, read_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, read_err, nil)
	testing.expect_value(t, string(saved), string(bytes))
	names: [dynamic]string
	sources: [dynamic]Emoji_Source
	defer {
		for name in names {delete(name)}; delete(names)
		for source in sources {delete(source.name); delete(source.title); delete(source.author); delete(source.coordinate)}
		delete(sources)
	}
	emoji_scan_files(directory, &names, &sources)
	testing.expect_value(t, len(names), 1)
	testing.expect_value(t, len(sources), 1)
	if len(names) != 1 || len(sources) != 1 {return}
	testing.expect_value(t, emoji_code(names[0]), "happy-fox")
	testing.expect_value(t, emoji_basename(names[0]), "happy-fox.png")
	testing.expect_value(t, sources[0].title, "Woodland")
	testing.expect_value(t, sources[0].author, event.pubkey)
	testing.expect_value(t, sources[0].coordinate, set.coordinate)
	previous_sources := emoji_sources
	emoji_sources = sources
	title, author, coordinate := emoji_source_for(names[0])
	emoji_sources = previous_sources
	testing.expect_value(t, title, "Woodland")
	testing.expect_value(t, author, event.pubkey)
	testing.expect_value(t, coordinate, set.coordinate)
	// A local override wins deterministically and has no imported attribution.
	testing.expect_value(
		t,
		os.write_entire_file(fmt.tprintf("%s/happy-fox.png", directory), bytes),
		nil,
	)
	local_names: [dynamic]string
	local_sources: [dynamic]Emoji_Source
	defer {
		for name in local_names {delete(name)}; delete(local_names)
		for source in local_sources {delete(source.name); delete(source.title); delete(source.author); delete(source.coordinate)}
		delete(local_sources)
	}
	emoji_scan_files(directory, &local_names, &local_sources)
	testing.expect_value(t, len(local_names), 1)
	testing.expect_value(t, local_names[0], "happy-fox.png")
	testing.expect_value(t, len(local_sources), 0)
	os.remove(fmt.tprintf("%s/happy-fox.png", directory))
	// Metadata filenames are untrusted even though the original event is signed.
	manifest, loaded := emoji_manifest_load(directory, event.id)
	testing.expect(t, loaded)
	manifest.files[0].name = "../../escape.png"
	testing.expect(
		t,
		emoji_manifest_write(fmt.tprintf("%s/sets/%s/source.json", directory, event.id), manifest),
	)
	_, accepted := emoji_manifest_load(directory, event.id)
	testing.expect(t, !accepted)
}

@(test)
emoji_import_mutation_guard :: proc(t: ^testing.T) {
	job := Emoji_Set_Job {
		op = .Import,
	}
	ui := Ui_State {
		emoji_sets_job = &job,
		emoji_staged   = "not-a-file",
	}
	save_staged_emoji(&ui)
	testing.expect(
		t,
		ui.emoji_staged == "not-a-file",
		"an active import must not consume a staged upload",
	)
	emoji_remove(&ui, "not-a-file.png")
	testing.expect(
		t,
		ui.keys_confirm == "",
		"an active import must not arm or remove another emoji",
	)
}

@(test)
emoji_set_contact_order :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	first :: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
	second :: "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"
	ui := Ui_State{}
	append(
		&ui.emoji_sets,
		Nostr_Emoji_Set{title = "Alpha", author = first},
		Nostr_Emoji_Set{title = "Beta", author = first},
		Nostr_Emoji_Set{title = "Zeta", author = second},
		Nostr_Emoji_Set{title = "Empty stranger set", author = first},
		Nostr_Emoji_Set{title = "Empty contact set", author = second},
	)
	for &set in ui.emoji_sets[:3] {append(&set.items, Nostr_Emoji_Item{code = "fox"})}
	append(&ui.contacts, Contact_Ui{id_hex = second})
	emoji_sets_order(&ui)
	testing.expect(
		t,
		slice.equal(ui.emoji_sets_order[:], []int{2, 0, 1}),
		"contacts precede strangers and empty sets stay hidden",
	)
	ui.prefs.emoji_contacts_only = true
	emoji_sets_order(&ui)
	testing.expect(
		t,
		slice.equal(ui.emoji_sets_order[:], []int{2}),
		"contacts-only hides non-contact sets and empty contact sets",
	)
	clear(&ui.contacts)
	emoji_sets_order(&ui)
	testing.expect(
		t,
		len(ui.emoji_sets_order) == 0,
		"removed contacts stop qualifying immediately",
	)
	ui.prefs.emoji_contacts_only = false
	emoji_sets_order(&ui)
	testing.expect(
		t,
		slice.equal(ui.emoji_sets_order[:], []int{0, 1, 2}),
		"showing all sets restores A-Z without revealing empty sets",
	)
}
