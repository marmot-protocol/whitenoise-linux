package main

import "core:strings"
import "core:testing"

@(test)
password_guess_resistance :: proc(t: ^testing.T) {
	check: Password_Check
	for password in ([]string{"", "x", "password", "Password123!", "qwertyuiop123!", "12345678901234567890", "abcdefghijklmnopqrstuvwxyz0123456789", "qwertyuiopasdfghjklzxcvbnm", "mnbvcxzlkjhgfdsapoiuytrewq", "films+pic+galeries", "F1lm5+P1c+G4ler1e5", "password____________________", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "abcabcabcabcabcabcabcabc", "password123password123password123password123", "ああああああああああああああああ"}) {
		testing.expect(t, password_bits(password, &check) < PASSWORD_MIN_BITS, password)
	}
	for password in ([]string{"marmot on burrowed time thimble lantern", "P@ssw0rd-Welcome-Monkey-Dragon-Marmot", "marmotjvqkfhzmtpwrcnsb", "マーモットはもっと穴でまったり"}) {
		testing.expect(t, password_bits(password, &check) >= PASSWORD_MIN_BITS, password)
	}
}

@(test)
password_edit_cache :: proc(t: ^testing.T) {
	check: Password_Check
	strong := "marmotjvqkfhzmtpwrcnsb"
	weak := strings.repeat("a", len(strong), context.temp_allocator)
	strong_bits := password_bits(strong, &check)
	testing.expect(t, strong_bits >= PASSWORD_MIN_BITS)
	testing.expect(t, password_bits(weak, &check) < PASSWORD_MIN_BITS)
	testing.expect_value(t, password_bits(strong, &check), strong_bits)
	testing.expect_value(t, password_bits("", &check), f64(0))
	for byte in check.sample {testing.expect_value(t, byte, u8(0))}

	prefix := strings.repeat("a", PASSWORD_SAMPLE_RUNES, context.temp_allocator)
	long := strings.concatenate({prefix, strong}, context.temp_allocator)
	testing.expect(t, password_bits(long, &check) < PASSWORD_MIN_BITS)
	// Multibyte input is bounded by characters, not a split UTF-8 byte prefix.
	unicode := strings.repeat("あ", PASSWORD_SAMPLE_RUNES + 1, context.temp_allocator)
	testing.expect(t, password_bits(unicode, &check) < PASSWORD_MIN_BITS)
	testing.expect_value(t, check.length, PASSWORD_SAMPLE_RUNES * len("あ"))
}
