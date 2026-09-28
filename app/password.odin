package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:sync"

import clay "../vendor/clay/bindings/odin/clay-odin"

@(private)
PASSWORD_MIN_BITS :: 40
@(private)
PASSWORD_SAMPLE_RUNES :: 100

@(private = "file")
PASSWORD_SEQ_FLAG :: u8(0x80)
@(private = "file")
PASSWORD_PERIOD_MASK :: u8(0x7f)
@(private = "file")
PASSWORD_SEQUENCE_BITS :: 6.0 // 32 starting positions, two directions
@(private = "file")
PASSWORD_BUCKET_COUNT :: 256

@(private = "file")
PASSWORD_CORPUS := #load("../vendor/common-passwords.txt", string)
@(private = "file")
PASSWORD_WORD_SLOTS :: 16384
@(private = "file")
PASSWORD_HASH_SEED :: u64(14695981039346656037)
@(private = "file")
PASSWORD_HASH_PRIME :: u64(1099511628211)

@(private = "file")
Password_Word :: struct {
	hash:   u64,
	start:  u32,
	length: u16,
	rank:   u16,
}

@(private = "file")
password_words: [PASSWORD_WORD_SLOTS]Password_Word
@(private = "file")
password_words_once: sync.Once

@(private = "file")
password_fold :: proc(input: rune) -> rune {
	char := input
	if char >= 'A' && char <= 'Z' {char += 'a' - 'A'}
	switch char {
	case '0':
		return 'o'
	case '1', '!':
		return 'i'
	case '3':
		return 'e'
	case '4', '@':
		return 'a'
	case '5', '$':
		return 's'
	case '7', '+':
		return 't'
	case '8':
		return 'b'
	}
	return char
}

// Offsets refer to the embedded corpus; the index owns no heap allocations.
@(private = "file")
password_corpus_init :: proc() {
	start, rank := 0, 0
	for end in 0 ..= len(PASSWORD_CORPUS) {
		if end < len(PASSWORD_CORPUS) && PASSWORD_CORPUS[end] != '\n' {continue}
		word := PASSWORD_CORPUS[start:end]
		if len(word) > 0 && word[len(word) - 1] == '\r' {word = word[:len(word) - 1]}
		if len(word) > 0 {
			rank += 1
			assert(rank < len(password_words) && len(word) <= 65535)
			hash := PASSWORD_HASH_SEED
			for char in word {hash = (hash ~ u64(password_fold(char))) * PASSWORD_HASH_PRIME}
			slot := int(hash & u64(len(password_words) - 1))
			for password_words[slot].rank != 0 {slot = (slot + 1) & (len(password_words) - 1)}
			password_words[slot] = {hash, u32(start), u16(len(word)), u16(rank)}
		}
		start = end + 1
	}
}

// Only whole-password matches count. Common words inside a passphrase do not.
@(private = "file")
password_corpus_bits :: proc(chars: []rune) -> (bits: f64, found: bool) {
	sync.once_do(&password_words_once, password_corpus_init)
	folded: [PASSWORD_SAMPLE_RUNES]rune
	hash := PASSWORD_HASH_SEED
	for char, index in chars {
		folded[index] = password_fold(char)
		hash = (hash ~ u64(folded[index])) * PASSWORD_HASH_PRIME
	}
	slot := int(hash & u64(len(password_words) - 1))
	for {
		entry := &password_words[slot]
		if entry.rank == 0 {return 0, false}
		if entry.hash == hash {
			word := PASSWORD_CORPUS[int(entry.start):int(entry.start) + int(entry.length)]
			index := 0
			matches := true
			for char in word {
				if index == len(chars) ||
				   password_fold(char) != folded[index] {matches = false; break}
				index += 1
			}
			if matches && index == len(chars) {return math.log2(f64(entry.rank)), true}
		}
		slot = (slot + 1) & (len(password_words) - 1)
	}
}

@(private)
Password_Check :: struct {
	sample: [PASSWORD_SAMPLE_RUNES * 4]u8,
	length: int,
	bits:   f64,
}

// Reuse the estimate until the evaluated prefix changes. Owners wipe the cache
// when closing a password dialog, along with its input buffers.
@(private)
password_bits :: proc(password: string, check: ^Password_Check) -> f64 {
	sample := password
	count := 0
	for _, index in password {
		if count == PASSWORD_SAMPLE_RUNES {
			sample = password[:index]
			break
		}
		count += 1
	}
	if len(sample) == check.length && sample == string(check.sample[:check.length]) {
		return check.bits
	}
	mem.zero_slice(check.sample[:])
	copy(check.sample[:], transmute([]u8)sample)
	check.length = len(sample)
	check.bits = password_estimate(sample)
	return check.bits
}

// Known whole passwords use their corpus rank. Otherwise character diversity
// is discounted by sequences and repeated blocks, not by constituent words.
@(private = "file")
password_estimate :: proc(password: string) -> f64 {
	chars: [PASSWORD_SAMPLE_RUNES]rune
	keys: [PASSWORD_BUCKET_COUNT]rune
	occupied: [PASSWORD_BUCKET_COUNT]bool
	count, unique := 0, 0
	for input in password {
		if count == len(chars) {break}
		char := input
		if char >= 'A' && char <= 'Z' {char += 'a' - 'A'}
		slot := int(u32(char) & u32(len(keys) - 1))
		for occupied[slot] && keys[slot] != char {slot = (slot + 1) & (len(keys) - 1)}
		if !occupied[slot] {
			keys[slot], occupied[slot] = char, true
			unique += 1
		}
		chars[count] = char
		count += 1
	}
	if count == 0 {return 0}
	if bits, found := password_corpus_bits(chars[:count]); found {return bits}

	logs: [PASSWORD_SAMPLE_RUNES + 1]f64
	for i in 1 ..= count {logs[i] = math.log2(f64(i))}
	keyboard: [128]int
	for char, index in "qwertyuiopasdfghjklzxcvbnm" {keyboard[char] = index + 1}

	// Prefix-function periods find all repeated blocks in O(n^2), without
	// allocating substrings or rescanning every possible repetition length.
	patterns: [PASSWORD_SAMPLE_RUNES][PASSWORD_SAMPLE_RUNES]u8
	prefix: [PASSWORD_SAMPLE_RUNES]int
	for start in 0 ..< count {
		prefix[0] = 0
		patterns[start][start] = 1
		sequence, key_sequence := true, true
		delta, key_delta: int
		for end in start + 1 ..< count {
			length := end - start + 1
			matched := prefix[length - 2]
			for matched > 0 && chars[start + matched] != chars[end] {matched = prefix[matched - 1]}
			if chars[start + matched] == chars[end] {matched += 1}
			prefix[length - 1] = matched
			period := length - matched
			patterns[start][end] = u8(length % period == 0 ? period : length)

			step := int(chars[end] - chars[end - 1])
			key_step := 0
			if chars[end] < 128 &&
			   chars[end - 1] < 128 &&
			   keyboard[chars[end]] > 0 &&
			   keyboard[chars[end - 1]] > 0 {
				key_step = keyboard[chars[end]] - keyboard[chars[end - 1]]
			}
			if length == 2 {
				delta, key_delta = step, key_step
				sequence = abs(delta) == 1
				key_sequence = abs(key_delta) == 1
			} else {
				sequence = sequence && step == delta
				key_sequence = key_sequence && key_step == key_delta
			}
			if length >= 3 &&
			   (sequence || key_sequence) {patterns[start][end] |= PASSWORD_SEQ_FLAG}
		}
	}

	best: [PASSWORD_SAMPLE_RUNES + 1]f64
	for end in 1 ..= count {
		char_bits := logs[unique]
		// Conventional word separators do not add strength to a passphrase.
		if chars[end - 1] == ' ' || chars[end - 1] == '-' || chars[end - 1] == '_' {char_bits = 0}
		best[end] = best[end - 1] + char_bits
		for start in 0 ..< end - 1 {
			length := end - start
			pattern := patterns[start][end - 1]
			period := int(pattern & PASSWORD_PERIOD_MASK)
			if period <
			   length {best[end] = min(best[end], best[start + period] + logs[length / period])}
			if pattern & PASSWORD_SEQ_FLAG != 0 {
				best[end] = min(best[end], best[start] + PASSWORD_SEQUENCE_BITS + logs[length])
			}
		}
	}
	return best[count]
}

@(private)
password_hint :: proc(bits: f64) {
	clay.Text(
		fmt.tprintf(
			tr("Estimated strength: %d bits. Required: %d."),
			int(bits),
			PASSWORD_MIN_BITS,
		),
		{
			fontId = FONT_BODY,
			fontSize = 12,
			textColor = bits >= PASSWORD_MIN_BITS ? ACCENT : TEXT_DIM,
		},
	)
	clay.Text(
		tr("Use unrelated words or a password-manager password."),
		{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
	)
}
