package main

import "core:testing"

@(test)
avatar_unicode_initials :: proc(t: ^testing.T) {
	for sample in ([][2]string{
		{"", ""}, {"A", "A"}, {"Alice", "Al"}, {"Dee Kay", "DK"},
		{"⚡ Dee Kay ⚡", "⚡D"}, {"👩🏽‍💻 Alice", "👩🏽‍💻A"},
		{"🇮🇹🇯🇵🇩🇪", "🇮🇹🇯🇵"}, {"Élodie Noël", "ÉN"},
		{"éclair", "éc"}, {"日本語", "日本"}, {"𝓡𝔂𝓪𝓷", "𝓡𝔂"},
	}) {
		testing.expect_value(t, avatar_initials(sample[0]), sample[1])
	}
}
