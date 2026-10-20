package main

import "core:testing"

@(test)
chat_list_empty_names_the_filter :: proc(t: ^testing.T) {
	testing.expect_value(t, chat_rail_empty(3, 1, true, true), Chat_Rail_Empty.None)
	testing.expect_value(t, chat_rail_empty(0, 0, false, false), Chat_Rail_Empty.No_Chats)
	testing.expect_value(t, chat_rail_empty(0, 0, true, true), Chat_Rail_Empty.No_Chats)
	testing.expect_value(t, chat_rail_empty(3, 0, true, false), Chat_Rail_Empty.No_Matches)
	testing.expect_value(t, chat_rail_empty(3, 0, false, true), Chat_Rail_Empty.No_Unread)
	// The search text is the part you can edit, so it wins over Unread.
	testing.expect_value(t, chat_rail_empty(3, 0, true, true), Chat_Rail_Empty.No_Matches)
}
