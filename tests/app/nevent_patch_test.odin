package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
patch_metadata :: proc(t: ^testing.T) {
	for ending in ([]string{"\n", "\r\n"}) {
		content := "From 0123456789abcdef Mon Sep 17 00:00:00 2001\nSubject: [PATCH v3 2/4] Keep **literal**\n\tcode readable\n\nExplain the change.\n\n---\n misleading diffstat: 500 insertions\n\ndiff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1,2 @@\n--- removed text\n+++ added text\n+another addition\n\\ No newline at end of file\ndiff --git a/icon.png b/icon.png\nGIT binary patch\nliteral 0\nHcmV?d00001\n-- \n2.50.0\n"
		if ending ==
		   "\r\n" {content, _ = strings.replace_all(content, "\n", ending, context.temp_allocator)}
		encoded, _ := json.marshal(content, {}, context.temp_allocator)
		event := fmt.tprintf(
			`{{"kind":1617,"pubkey":"author","content":%s,"tags":[null,[],["a"],["a",42],["a","30617:bad:ignored"],["a","30617:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:repo:subproject"]]}}`,
			string(encoded),
		)
		card := nev_parse(transmute([]u8)event, .Event)
		defer nev_patch_test_free(card)
		testing.expect_value(t, card.subject, "Keep **literal** code readable")
		testing.expect_value(t, card.patch.series, "v3 2/4")
		testing.expect_value(t, card.patch.repository, "repo:subproject")
		testing.expect_value(t, card.patch.description, "Explain the change.")
		testing.expect_value(t, card.patch.files, 2)
		testing.expect_value(t, card.patch.added, 2)
		testing.expect_value(t, card.patch.removed, 1)
		for line in card.patch.lines {testing.expect(t, line.text != "2.50.0", "Mail signatures are not part of the diff.")}
	}
	for content in ([]string{"Subject: [PATCH 0/2] A cover letter\n\nDescribe the series.\n\n---\n a.txt | 1 +\n", "Unstructured patch content."}) {
		encoded, _ := json.marshal(content, {}, context.temp_allocator)
		card := nev_parse(
			transmute([]u8)fmt.tprintf(
				`{{"kind":1617,"pubkey":"author","content":%s,"tags":[]}}`,
				string(encoded),
			),
			.Event,
		)
		defer nev_patch_test_free(card)
		testing.expect_value(t, len(card.patch.lines), 0)
		testing.expect_value(t, card.patch.files, 0)
		testing.expect_value(
			t,
			card.patch.description,
			strings.has_prefix(content, "Subject:") ? "Describe the series." : content,
		)
	}
}

@(private)
nev_patch_test_free :: proc(card: Nev_Card) {
	delete(card.raw); delete(card.content); delete(card.pubkey)
	delete(card.subject); delete(card.subject_fonts)
	delete(card.patch.repository); delete(card.patch.series); delete(card.patch.lines)
}
