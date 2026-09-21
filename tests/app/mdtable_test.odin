package main

import "core:testing"

import marmot "../marmot"

// Assemble a raw marmot TABLE block (2-column header, one body row)
// and check convert_blocks turns it into one .Table Md_Block_Ui with
// the cell text in place.
@(test)
test_convert_table :: proc(t: ^testing.T) {
	txt :: proc(s: cstring) -> marmot.Markdown_Inline {
		span: marmot.Markdown_Inline
		span.tag = .TEXT
		span.body.text.content = s
		return span
	}

	h0 := [1]marmot.Markdown_Inline{txt("Name")}
	h1 := [1]marmot.Markdown_Inline{txt("Age")}
	c0 := [1]marmot.Markdown_Inline{txt("Ada")}
	c1 := [1]marmot.Markdown_Inline{txt("36")}

	header := [2]marmot.Markdown_Table_Cell {
		{inlines = &h0[0], inlines_len = 1},
		{inlines = &h1[0], inlines_len = 1},
	}
	body_cells := [2]marmot.Markdown_Table_Cell {
		{inlines = &c0[0], inlines_len = 1},
		{inlines = &c1[0], inlines_len = 1},
	}
	rows := [1]marmot.Markdown_Table_Row{{cells = &body_cells[0], cells_len = 2}}
	aligns := [2]marmot.Markdown_Alignment{.None, .Right}

	block: marmot.Markdown_Block
	block.tag = .TABLE
	block.body.table = {
		alignments     = &aligns[0],
		alignments_len = 2,
		header         = &header[0],
		header_len     = 2,
		rows           = &rows[0],
		rows_len       = 1,
	}

	out: [dynamic]Md_Block_Ui
	convert_blocks(&out, &block, 1, false)

	testing.expect(t, len(out) == 1)
	testing.expect(t, out[0].kind == .Table)
	testing.expect(t, len(out[0].cells) == 2)
	testing.expect(t, out[0].cells[0][0] == "Name" && out[0].cells[0][1] == "Age")
	testing.expect(t, out[0].cells[1][0] == "Ada" && out[0].cells[1][1] == "36")
}
