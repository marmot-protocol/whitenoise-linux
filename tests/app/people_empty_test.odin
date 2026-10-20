// People page empty states: a search with no hits, an empty list and a
// collapsed list each say something different.
// Run: tests/odin.sh app -define:ODIN_TEST_NAMES=main.contacts_empty_tells_search_from_none,main.contact_note_follows_list_state
package main

import "core:testing"

@(test)
contacts_empty_tells_search_from_none :: proc(t: ^testing.T) {
	testing.expect_value(t, contacts_empty(0, 0, 0), Contacts_Empty.No_Contacts)
	// Typing into an empty list is still a search that found no one.
	testing.expect_value(t, contacts_empty(0, 0, 4), Contacts_Empty.No_Matches)
	testing.expect_value(t, contacts_empty(3, 0, 4), Contacts_Empty.No_Matches)
	testing.expect_value(t, contacts_empty(3, 1, 4), Contacts_Empty.None)
	testing.expect_value(t, contacts_empty(3, 3, 0), Contacts_Empty.None)
}

@(test)
contact_note_follows_list_state :: proc(t: ^testing.T) {
	testing.expect_value(t, contact_note(3, false), Contact_Note.Pick)
	testing.expect_value(t, contact_note(3, true), Contact_Note.Collapsed)
	// Nothing to select whether or not the list is open.
	testing.expect_value(t, contact_note(0, false), Contact_Note.No_Contacts)
	testing.expect_value(t, contact_note(0, true), Contact_Note.No_Contacts)
}
