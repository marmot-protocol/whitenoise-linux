// Word-level diff for the edit-history modal, mirroring the slint
// app's edit_diff.rs: unchanged words follow the longest common
// subsequence, everything else is Removed/Added.
package main

import marmot "../marmot"
import "core:strings"

// Parse complete revisions once, before the modal starts laying out frames.
@(private)
history_version :: proc(client: ^marmot.Client, at: u64, text: string) -> Edit_Version {
	version := Edit_Version {
		at   = format_when(at),
		text = strings.clone(text),
	}
	doc: ^marmot.Markdown_Document
	if client != nil &&
	   text != "" &&
	   marmot.parse_markdown(
		   client,
		   strings.clone_to_cstring(text, context.temp_allocator),
		   &doc,
	   ) ==
		   .OK {
		defer marmot.markdown_document_free(doc)
		convert_blocks(
			&version.blocks,
			doc.blocks,
			doc.blocks_len,
			false,
			([^]u8)(doc.blank_lines_before)[:doc.blank_lines_before_len],
		)
	}
	if len(version.blocks) == 0 && text != "" {
		append(&version.blocks, Md_Block_Ui{kind = .Para, text = strings.clone(text)})
	}
	return version
}

@(private)
History_Span :: struct {
	text:  string,
	fonts: ^string,
	block: ^Md_Block_Ui,
	start: int,
}

// Keep byte offsets back into owned Markdown styles while diffing visible words.
@(private)
history_spans :: proc(blocks: []Md_Block_Ui) -> (string, []History_Span) {
	spans := make([dynamic]History_Span, context.temp_allocator)
	for &block in blocks {
		if block.text !=
		   "" {append(&spans, History_Span{text = block.text, fonts = &block.fonts, block = &block})}
		for row, r in block.cells {
			for cell, c in row {
				if cell !=
				   "" {append(&spans, History_Span{text = cell, fonts = &block.cell_fonts[r][c], block = &block})}
			}
		}
	}
	text := strings.builder_make(context.temp_allocator)
	for &span in spans {
		if span.fonts^ == "" {
			font := [1]u8 {
				span.block.kind == .Code || span.block.kind == .Math ? FONT_MONO : FONT_BODY,
			}
			span.fonts^ = strings.repeat(string(font[:]), len(span.text))
		}
		span.start = strings.builder_len(text)
		strings.write_string(&text, span.text)
		strings.write_byte(&text, '\n')
	}
	return strings.to_string(text), spans[:]
}

@(private)
history_highlight :: proc(versions: []Edit_Version) {
	for i in 1 ..< len(versions) {
		before, a := history_spans(versions[i - 1].blocks[:])
		after, b := history_spans(versions[i].blocks[:])
		texts := [2]string{before, after}
		spans := [2][]History_Span{a, b}
		cursor, index: [2]int
		for run in diff_words(before, after) {
			styles: [2][]u8
			blocks: [2]^Md_Block_Ui
			for side in 0 ..< 2 {
				if (side == 0 && run.kind == .Added) ||
				   (side == 1 && run.kind == .Removed) {continue}
				start := cursor[side] + strings.index(texts[side][cursor[side]:], run.text)
				cursor[side] = start + len(run.text)
				for index[side] + 1 < len(spans[side]) &&
				    spans[side][index[side] + 1].start <= start {index[side] += 1}
				span := spans[side][index[side]]
				bytes := transmute([]u8)span.fonts^
				styles[side] = bytes[start - span.start:cursor[side] - span.start]
				blocks[side] = span.block
			}
			if run.kind == .Same {
				changed :=
					blocks[0].kind != blocks[1].kind ||
					blocks[0].level != blocks[1].level ||
					blocks[0].indent != blocks[1].indent ||
					blocks[0].quote_depth != blocks[1].quote_depth
				for font, j in styles[0] {
					changed =
						changed ||
						font & ~(TEXT_ADDED | TEXT_REMOVED) !=
							styles[1][j] & ~(TEXT_ADDED | TEXT_REMOVED)
				}
				if !changed {continue}
			}
			for side in 0 ..< 2 {
				for &font in styles[side] {font |= side == 0 ? TEXT_REMOVED : TEXT_ADDED}
			}
		}
	}
}

Diff_Kind :: enum {
	Same,
	Removed,
	Added,
}

Diff_Run :: struct {
	kind: Diff_Kind,
	text: string, // one word, a slice of the input text
}

// Word diff of prev -> next, ignoring whitespace. Runs borrow their input
// words. O(n*m) LCS table; removed words precede added ones within a gap.
diff_words :: proc(prev, next: string, allocator := context.temp_allocator) -> [dynamic]Diff_Run {
	a := strings.fields(prev, allocator)
	b := strings.fields(next, allocator)
	n, m := len(a), len(b)

	// dp[i * (m+1) + j] = LCS length of a[i:] vs b[j:].
	dp := make([]int, (n + 1) * (m + 1), allocator)
	for i := n - 1; i >= 0; i -= 1 {
		for j := m - 1; j >= 0; j -= 1 {
			at := i * (m + 1) + j
			if a[i] == b[j] {
				dp[at] = dp[at + m + 2] + 1
			} else {
				dp[at] = max(dp[at + m + 1], dp[at + 1])
			}
		}
	}

	out := make([dynamic]Diff_Run, allocator)
	i, j := 0, 0
	for i < n && j < m {
		if a[i] == b[j] {
			append(&out, Diff_Run{.Same, a[i]})
			i += 1
			j += 1
		} else if dp[(i + 1) * (m + 1) + j] >= dp[i * (m + 1) + j + 1] {
			append(&out, Diff_Run{.Removed, a[i]})
			i += 1
		} else {
			append(&out, Diff_Run{.Added, b[j]})
			j += 1
		}
	}
	for ; i < n; i += 1 {
		append(&out, Diff_Run{.Removed, a[i]})
	}
	for ; j < m; j += 1 {
		append(&out, Diff_Run{.Added, b[j]})
	}
	return out
}
