package main

import marmot "../marmot"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
trailing_image_links :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("/tmp", "wn-image-tail-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	deployment: ^marmot.Deployment
	if !testing.expect_value(
		t,
		marmot.deployment_white_noise(&deployment),
		marmot.Status.OK,
	) {return}
	defer marmot.deployment_free(deployment)
	client: ^marmot.Client
	store := vault_secret_store()
	if !testing.expect_value(
		t,
		marmot.client_new_with_secret_store(
			strings.clone_to_cstring(dir, context.temp_allocator),
			nil,
			0,
			&store,
			deployment,
			&client,
		),
		marmot.Status.OK,
	) {return}
	defer marmot.client_free(client)
	a :: "https://blossom.primal.net/a.png"
	b :: "https://blossom.primal.net/b.PNG?size=large#image"
	Case :: struct {
		source: string,
		urls:   []string,
	}
	cases := []Case {
		{"Announcement\n\nWeb: https://example.org/\n\n" + a + "\n\n" + b + " \n", {a, b}},
		{a + "\n" + b, {a, b}},
		{"<" + a + ">\n\n<" + b + ">", {a, b}},
		{"Announcement\n\n" + a, nil},
		{a + "\n\n" + b + "\n\nMore text", nil},
		{"See " + a + "\n\n" + b, nil},
		{a + "\n\n`" + b + "`", nil},
		{a + "\n\n```\n" + b + "\n```", nil},
		{a + "\n\n[" + b + "](https://different.example/image.png)", nil},
		{"> " + a + "\n>\n> " + b, nil},
		{"- " + a + "\n- " + b, nil},
		{a + "\n\nhttps://example.org/\n\n" + a + "\n\n" + b, {a, b}},
	}
	for test in cases {
		doc: ^marmot.Markdown_Document
		if !testing.expect_value(
			t,
			marmot.parse_markdown(
				client,
				strings.clone_to_cstring(test.source, context.temp_allocator),
				&doc,
			),
			marmot.Status.OK,
		) {continue}
		blocks: [dynamic]Md_Block_Ui
		convert_blocks(&blocks, doc.blocks, doc.blocks_len, false)
		marmot.markdown_document_free(doc)
		_, cells := md_image_tail(blocks[:])
		testing.expect(t, len(cells) == len(test.urls), test.source)
		for cell, i in cells {
			if i < len(test.urls) {testing.expect_value(t, cell.key, test.urls[i])}
		}
		blocks_free(blocks)
	}
}
