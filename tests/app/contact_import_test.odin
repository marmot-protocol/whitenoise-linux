package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
contacts_import_roundtrip :: proc(t: ^testing.T) {
	npub := hex_npub(strings.repeat("ab", 32, context.temp_allocator))
	defer delete(npub)
	input := []Contacts_File_Row {
		{
			name = "Alice, \"A\"\n第二行",
			npub = npub,
			nickname = "friend\nwith, commas",
			blocked = true,
		},
		{name = "", npub = npub, nickname = "", blocked = false},
	}
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "name,npub,nickname,blocked\n")
	for row in input {
		csv_field(&builder, row.name); strings.write_byte(&builder, ',')
		csv_field(&builder, row.npub); strings.write_byte(&builder, ',')
		csv_field(&builder, row.nickname)
		fmt.sbprintf(&builder, ",%t\n", row.blocked)
	}
	json_bytes, err := json.marshal(input, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	for bytes, i in ([][]u8{builder.buf[:], json_bytes}) {
		rows, error, _ := contacts_parse(bytes, Contacts_Kind(i))
		testing.expect_value(t, error, "")
		testing.expect_value(t, len(rows), len(input))
		if len(rows) != len(input) {continue}
		for row, j in rows {
			testing.expect_value(t, row.name, input[j].name)
			testing.expect_value(t, row.npub, input[j].npub)
			testing.expect_value(t, row.nickname, input[j].nickname)
			testing.expect_value(t, row.blocked, input[j].blocked)
		}
	}
}

@(test)
contacts_import_bad_files :: proc(t: ^testing.T) {
	for input in ([]string{"name,npub,nickname\nAlice,npub,,true\n", "name,npub,nickname,blocked\n\"unterminated,npub,,true\n", "name,npub,nickname,blocked\nAlice,npub,,true\nBob,npub,\n", "name,npub,nickname,blocked\nAlice,npub,,yes\n"}) {
		_, error, _ := contacts_parse(transmute([]u8)input, .Csv)
		testing.expect(t, error != "", input)
	}
	for input in ([]string{"{}", "[", "null", "[1]", `[{"name":"A","npub":"npub","nickname":""}]`, `[{"name":"A","npub":"npub","nickname":"","blocked":"false"}]`, `[{"name":"A","npub":"npub","nickname":"","blocked":false},{"name":1,"npub":"npub","nickname":"","blocked":false}]`}) {
		_, error, _ := contacts_parse(transmute([]u8)input, .Json)
		testing.expect(t, error != "", input)
	}
	_, error, row := contacts_parse(
		transmute([]u8)string(`[{"name":"A","npub":"npub","nickname":"","blocked":false},{}]`),
		.Json,
	)
	testing.expect(t, error != "")
	testing.expect_value(t, row, 2)
}

@(test)
contacts_import_empty :: proc(t: ^testing.T) {
	rows, error, _ := contacts_parse(
		transmute([]u8)string("name,npub,nickname,blocked\r\n\"A\"\"B\",npub,\"\",false\r\n"),
		.Csv,
	)
	testing.expect_value(t, error, "")
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {testing.expect_value(t, rows[0].name, "A\"B")}
	for input, i in ([]string{"name,npub,nickname,blocked\n", "[]"}) {
		rows, error, _ := contacts_parse(transmute([]u8)input, Contacts_Kind(i))
		testing.expect_value(t, error, "")
		testing.expect_value(t, len(rows), 0)
	}
}

@(test)
contacts_import_dedup :: proc(t: ^testing.T) {
	key := strings.repeat("ab", 32, context.temp_allocator)
	npub := hex_npub(key)
	defer delete(npub)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	decoded, duplicate, valid := contacts_import_key(npub, &seen)
	testing.expect(t, valid && !duplicate)
	testing.expect_value(t, decoded, key)
	_, duplicate, valid = contacts_import_key(
		strings.to_upper(npub, context.temp_allocator),
		&seen,
	)
	testing.expect(t, valid && duplicate)
	// The first occurrence stays reserved even when its follow call fails.
	_, duplicate, valid = contacts_import_key(npub, &seen)
	testing.expect(t, valid && duplicate)
	other := strings.repeat("cd", 32, context.temp_allocator)
	seen[other] = true // an existing account follow
	other_npub := hex_npub(other)
	defer delete(other_npub)
	_, duplicate, valid = contacts_import_key(other_npub, &seen)
	testing.expect(t, valid && duplicate)
	for bad in ([]string{"", "npub1invalid", "note1invalid", key}) {
		_, _, valid = contacts_import_key(bad, &seen)
		testing.expect(t, !valid)
	}
}
