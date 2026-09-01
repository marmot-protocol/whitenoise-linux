// Odin bindings for the marmot-c ABI (mdk PR #1575).
//
// Hand-written subset of vendor/mdk/crates/marmot-c/include/marmot.h,
// grown as the UI needs more surface. Ownership rules (see the header):
// every fallible call returns Status; root-returned pointers are freed
// only with their matching *_free; input strings/arrays are borrowed.
package marmot

foreign import lib {
	"../vendor/mdk/crates/marmot-c/output/lib/libmarmot_c.a",
	"system:m",
	"system:pthread",
	"system:dl",
}

// Mirrors `enum MarmotStatus`. 1-9 are binding-level failures; 10+
// mirror the runtime's typed error variants one-to-one.
Status :: enum i32 {
	OK                                          = 0,
	NULL_POINTER                                = 1,
	INVALID_UTF8                                = 2,
	PANIC_CAUGHT                                = 3,
	TIMEOUT                                     = 4,
	CLOSED                                      = 5,
	DUPLICATE_IDENTITY                          = 10,
	UNKNOWN_ACCOUNT                             = 11,
	UNKNOWN_GROUP                               = 12,
	INVALID_HEX                                 = 13,
	INVALID_IDENTITY                            = 14,
	MISSING_KEY_PACKAGE                         = 15,
	PUBLISH                                     = 16,
	TRANSPORT_CLOSED                            = 17,
	RUNTIME_STOPPING                            = 18,
	NOT_GROUP_ADMIN                             = 19,
	ADMIN_CANNOT_SELF_REMOVE                    = 20,
	WOULD_REMOVE_LAST_ADMIN                     = 21,
	MEMBER_NOT_IN_GROUP                         = 22,
	ALREADY_ADMIN                               = 23,
	NOT_ADMIN                                   = 24,
	STORAGE_BUSY                                = 25,
	SECRET_NOT_FOUND                            = 26,
	KEYSTORE_UNAVAILABLE                        = 27,
	EMPTY_PASSPHRASE                            = 28,
	ENCRYPTION_FAILED                           = 29,
	IO                                          = 30,
	RUNTIME                                     = 31,
	EXTERNAL_SIGNER_UNAVAILABLE                 = 32,
	EXTERNAL_SIGNER_MISMATCH                    = 33,
	EXTERNAL_SIGNER_REJECTED                    = 34,
	INVALID_GROUP_MEMBERSHIP_PAGE               = 35,
	GROUP_HYDRATION_PENDING                     = 36,
	INVALID_CHAT_PIN                            = 37,
	INVALID_MESSAGE_DRAFT                       = 38,
	INVALID_MEDIA_REFERENCE                     = 39,
	INVALID_KEY_PACKAGE_EVENT                   = 40,
	FOLLOW_LIST_UNAVAILABLE                     = 41,
	RUNTIME_BUSY                                = 42,
	ACCOUNT_SESSION_BUSY                        = 43,
	ACCOUNT_SETUP_RECOVERY_REQUIRED             = 44,
	ACCOUNT_SETUP_RETRY_REQUIRED                = 45,
	ACCOUNT_SETUP_RESET_NOT_APPLICABLE          = 46,
	ACCOUNT_SETUP_KEY_PACKAGE_RECOVERY_AVAILABLE = 47,
	ACCOUNT_CATCH_UP                            = 48,
	LEAVE_ALREADY_REQUESTED                     = 49,
	DISBANDING_UNSUPPORTED_MEMBERS              = 50,
	DISBANDING_NOT_ENABLED                      = 51,
	GROUP_DISBANDING                            = 52,
	STORAGE_CLOSED                              = 53,
	GROUP_SEND_QUEUE_FULL                       = 54,
	CREATED_GROUP_PROJECTION_UNAVAILABLE        = 55,
	INVALID_CACHED_IDENTITY_PAGE                = 56,
	DIRECT_CONVERSATION_INDEX_NOT_READY         = 57,
	GROUP_UNRECOVERABLE_REPAIR_REQUIRED         = 58,
	ACCOUNT_WORKER_BUSY                         = 59,
	ACCOUNT_WORKER_RESPONSE_TIMED_OUT           = 60,
}

// Opaque runtime handle.
Client :: struct {}

// Host-supplied storage for account signing keys, passed to
// client_new_with_secret_store instead of letting marmot use the
// platform keychain. The signing key crosses as secret-key hex; an
// account is identified by its label plus account_id_hex.
//
// The callbacks run on the runtime's worker threads and may run
// concurrently; they must not call any marmot_* function on the same
// client (the account home holds its mutation lock across the call) and
// must not unwind. The struct is copied at construction; user_data must
// outlive the client.
Secret_Store_Status :: enum u32 {
	OK,
	NOT_FOUND, // no credential for this account (load_secret only)
	UNAVAILABLE, // store exists but is unreachable now (locked vault)
	FAILED,
}

Secret_Store :: struct {
	user_data:                 rawptr,
	// Write nonzero to out_present when a credential exists.
	has_secret_for_label:      proc "c" (user_data: rawptr, key: cstring, out_present: ^u8) -> Secret_Store_Status,
	has_secret_for_account_id: proc "c" (user_data: rawptr, key: cstring, out_present: ^u8) -> Secret_Store_Status,
	write_secret:              proc "c" (user_data: rawptr, label: cstring, account_id_hex: cstring, secret_key_hex: cstring) -> Secret_Store_Status,
	// Writes a NUL-terminated hex string the library copies and returns
	// to free_secret.
	load_secret:               proc "c" (user_data: rawptr, label: cstring, account_id_hex: cstring, out_secret_key_hex: ^cstring) -> Secret_Store_Status,
	remove_secret:             proc "c" (user_data: rawptr, label: cstring, account_id_hex: cstring) -> Secret_Store_Status,
	free_secret:               proc "c" (user_data: rawptr, secret_key_hex: cstring),
	// Optional; fires when the last runtime reference is released.
	destroy:                   proc "c" (user_data: rawptr),
}

// Opaque subscription handle; free before the client that created it.
Chat_List_Subscription :: struct {}

Self_Membership :: enum i32 {
	MEMBER,
	LEFT,
	REMOVED,
}

Group_Lifecycle_State :: enum i32 {
	STABLE,
	PENDING_PUBLISH,
	MERGING,
	RECOVERING,
	UNRECOVERABLE,
	DISBANDED,
}

Chat_Conversation_Kind :: enum i32 {
	UNKNOWN,
	DIRECT,
	GROUP,
}

// Opaque here: reached only through Chat_List_Row, freed by its deep-free.
Disband_Request :: struct {}

Chat_List_Avatar :: struct {
	image_hash_hex:       cstring,
	image_key_hex:        cstring,
	image_nonce_hex:      cstring,
	image_upload_key_hex: cstring,
	media_type:           cstring,
}

Delivery_State :: enum i32 {
	NOT_APPLICABLE,
	PENDING,
	DELIVERED,
	FAILED,
}

// Full mirror of MarmotChatListMessagePreview.
Chat_List_Message_Preview :: struct {
	message_id_hex:      cstring,
	sender:              cstring,
	sender_display_name: cstring,
	plaintext:           cstring,
	content_tokens:      Markdown_Document,
	kind:                u64,
	timeline_at:         u64,
	deleted:             bool,
	has_attachment_kind: bool,
	attachment_kind:     i32,
	attachment_count:    u32,
	delivery_state:      Delivery_State,
}

#assert(size_of(Chat_List_Message_Preview) == 104)

// Full mirror of MarmotChatListRow.
Chat_List_Row :: struct {
	group_id_hex:                cstring,
	pinned:                      bool,
	has_pinned_position:         bool,
	pinned_position:             u32,
	archived:                    bool,
	pending_confirmation:        bool,
	lifecycle_state:             Group_Lifecycle_State,
	disbanding:                  bool,
	disband_request:             ^Disband_Request,
	title:                       cstring,
	group_name:                  cstring,
	avatar_url:                  cstring,
	avatar:                      ^Chat_List_Avatar,
	last_message:                ^Chat_List_Message_Preview,
	unread_count:                u64,
	has_unread:                  bool,
	manually_marked_unread:      bool,
	unread_mention_count:        u64,
	unread_mention:              bool,
	first_unread_message_id_hex: cstring,
	last_read_message_id_hex:    cstring,
	has_last_read_timeline_at:   bool,
	last_read_timeline_at:       u64,
	conversation_created_at:     u64,
	activity_sort_at:            u64,
	updated_at:                  u64,
	self_membership:             Self_Membership,
	conversation_kind:           Chat_Conversation_Kind,
	muted:                       bool,
	has_muted_until_ms:          bool,
	muted_until_ms:              i64,
	leave_request_pending:       bool,
	has_leave_requested_at_ms:   bool,
	leave_requested_at_ms:       u64,
}

Chat_List_Row_List :: struct {
	items: [^]Chat_List_Row,
	len:   uint,
}

Send_Accept_Disposition :: enum i32 {
	PUBLISHED,
	ACCEPTED_PENDING,
}

Send_Maintenance_Disposition :: enum i32 {
	READY,
	POST_JOIN_ROTATION_PENDING_RETRYABLE,
}

Send_Summary :: struct {
	published:               u32,
	message_ids:             [^]cstring,
	message_ids_len:         uint,
	accept_disposition:      Send_Accept_Disposition,
	maintenance_disposition: Send_Maintenance_Disposition,
}

Markdown_Inline_Tag :: enum i32 {
	TEXT,
	SOFT_BREAK,
	HARD_BREAK,
	CODE,
	EMPH,
	STRONG,
	STRIKETHROUGH,
	LINK,
	IMAGE,
	AUTOLINK,
	MATH,
	NOSTR_MENTION,
	NOSTR_URI,
}

Markdown_Children :: struct {
	children:     [^]Markdown_Inline,
	children_len: uint,
}

Markdown_Link_Body :: struct {
	dest:           cstring,
	title:          cstring, // nullable
	children:       [^]Markdown_Inline,
	children_len:   uint,
	classification: i32,
}

Markdown_Nostr_Entity :: struct {
	hrp:    i32,
	bech32: cstring,
}

Markdown_Inline :: struct {
	tag:  Markdown_Inline_Tag,
	body: struct #raw_union {
		text:          struct { content: cstring },
		code:          struct { content: cstring },
		emph:          Markdown_Children,
		strong:        Markdown_Children,
		strikethrough: Markdown_Children,
		link:          Markdown_Link_Body,
		image:         struct { dest: cstring, title: cstring, alt: [^]Markdown_Inline, alt_len: uint, classification: i32 },
		autolink:      struct { url: cstring, kind: i32, classification: i32 },
		math:          struct { content: cstring },
		nostr_mention: struct { entity: Markdown_Nostr_Entity },
		nostr_uri:     struct { entity: Markdown_Nostr_Entity },
	},
}

Markdown_Block_Tag :: enum i32 {
	PARAGRAPH,
	HEADING,
	THEMATIC_BREAK,
	CODE_BLOCK,
	BLOCK_QUOTE,
	LIST_BLOCK,
	TABLE,
	MATH_BLOCK,
}

Markdown_List_Kind :: struct {
	tag:  i32, // 0 = bullet, 1 = ordered
	body: struct #raw_union {
		bullet:  struct { marker: cstring },
		ordered: struct { start: u32, delimiter: cstring },
	},
}

Markdown_List_Item :: struct {
	blocks:                 [^]Markdown_Block,
	blocks_len:             uint,
	has_checked:            bool, // task-list state
	checked:                bool,
	blank_lines_before:     ^u8,
	blank_lines_before_len: uint,
}

Markdown_Inlines :: struct {
	inlines:     [^]Markdown_Inline,
	inlines_len: uint,
}

Markdown_Alignment :: enum i32 {
	None,
	Left,
	Center,
	Right,
}

Markdown_Table_Cell :: struct {
	inlines:     [^]Markdown_Inline,
	inlines_len: uint,
}

Markdown_Table_Row :: struct {
	cells:     [^]Markdown_Table_Cell,
	cells_len: uint,
}

Markdown_Block :: struct {
	tag:  Markdown_Block_Tag,
	body: struct #raw_union {
		paragraph:   Markdown_Inlines,
		heading:     struct { level: u8, inlines: [^]Markdown_Inline, inlines_len: uint },
		code_block:  struct { kind: i32, info: cstring, content: cstring },
		block_quote: struct { blocks: [^]Markdown_Block, blocks_len: uint, blank_lines_before: ^u8, blank_lines_before_len: uint },
		list_block:  struct { kind: Markdown_List_Kind, tight: bool, items: [^]Markdown_List_Item, items_len: uint },
		math_block:  struct { content: cstring },
		table:       struct { alignments: [^]Markdown_Alignment, alignments_len: uint, header: [^]Markdown_Table_Cell, header_len: uint, rows: [^]Markdown_Table_Row, rows_len: uint },
	},
}

Markdown_Document :: struct {
	blocks:                 [^]Markdown_Block,
	blocks_len:             uint,
	truncated:              bool,
	blank_lines_before:     ^u8,
	blank_lines_before_len: uint,
}

// Opaque outputs; freed with their matching free functions.
App_Group_Record :: struct {}
Group_Invite_Decline_Result :: struct {}
Sign_Out_Outcome :: struct {}
// One published relay list; `kind` is its Nostr event kind (10002
// NIP-65, 10050 inbox).
Relay_List :: struct {
	kind:       u64,
	relays:     [^]cstring,
	relays_len: uint,
}

// Which published list an incomplete relay setup is missing.
Missing_Relay_List_Kind :: enum i32 {
	NIP65,
	INBOX,
}

// An account's full relay-list state. Reached by pointer only, freed
// by account_relay_lists_free. Offsets from offsetof() under gcc
// against the vendored marmot.h.
Account_Relay_Lists :: struct {
	complete:             bool,
	missing:              [^]Missing_Relay_List_Kind,
	missing_len:          uint,
	default_relays:       [^]cstring,
	default_relays_len:   uint,
	bootstrap_relays:     [^]cstring,
	bootstrap_relays_len: uint,
	nip65:                Relay_List,
	inbox:                Relay_List,
}

#assert(size_of(Relay_List) == 24)
#assert(offset_of(Account_Relay_Lists, missing) == 8)
#assert(offset_of(Account_Relay_Lists, nip65) == 56)
#assert(offset_of(Account_Relay_Lists, inbox) == 80)
#assert(size_of(Account_Relay_Lists) == 104)

// Aggregate relay-pool counters (no per-relay identities).
Relay_Health :: struct {
	sdk_backed:                             bool,
	total_relays:                           u32,
	initialized:                            u32,
	pending:                                u32,
	connecting:                             u32,
	connected:                              u32,
	disconnected:                           u32,
	terminated:                             u32,
	banned:                                 u32,
	sleeping:                               u32,
	connection_attempts:                    u32,
	connection_successes:                   u32,
	notification_forwarder_running:         bool,
	notification_forwarder_restarts:        u64,
	notification_forwarder_lag_incidents:   u64,
	notification_forwarder_lagged_notifications: u64,
	notification_forwarder_panics:          u64,
	notification_forwarder_unexpected_exits: u64,
}

User_Profile_Metadata :: struct {
	name:         cstring,
	display_name: cstring,
	about:        cstring,
	picture:      cstring,
	banner:       cstring,
	nip05:        cstring,
	lud16:        cstring,
}

#assert(size_of(User_Profile_Metadata) == 56)

// TRUNCATED mirror of MarmotTimelineReplyPreview: leading pointer
// fields only (the full struct embeds the markdown document by
// value). Read through ^ only; never copy or size_of.
Timeline_Reply_Preview :: struct {
	message_id_hex: cstring,
	sender:         cstring,
	plaintext:      cstring,
}

Timeline_Reaction_Emoji :: struct {
	emoji:       cstring,
	count:       u32,
	senders:     [^]cstring,
	senders_len: uint,
}

Timeline_User_Reaction :: struct {
	reaction_message_id_hex: cstring,
	target_message_id_hex:   cstring,
	sender:                  cstring,
	emoji:                   cstring,
	reacted_at:              u64,
}

Timeline_Reaction_Summary :: struct {
	by_emoji:           [^]Timeline_Reaction_Emoji,
	by_emoji_len:       uint,
	user_reactions:     [^]Timeline_User_Reaction,
	user_reactions_len: uint,
}

// Input struct, borrowed by the call. Zero value = account-wide tail.
Timeline_Message_Query :: struct {
	group_id_hex:      cstring,
	search:            cstring,
	has_before:        bool,
	before:            u64,
	before_message_id: cstring,
	has_after:         bool,
	after:             u64,
	after_message_id:  cstring,
	has_limit:         bool,
	limit:             u32,
}

// Mirror of MarmotGroupSystemEvent: parsed view of a kind-1210 group
// system row (member/admin/rename/avatar/retention change). Reached by
// pointer only; freed by timeline_page_free.
Group_System_Event :: struct {
	system_type:               cstring,
	text:                      cstring, // human-readable fallback
	actor_account_id_hex:      cstring,
	subject_account_id_hex:    cstring,
	name:                      cstring,
	old_name:                  cstring,
	has_old_retention_seconds: bool,
	old_retention_seconds:     u64,
	has_new_retention_seconds: bool,
	new_retention_seconds:     u64,
}

// Mirror of MarmotMessageTag: one Nostr tag of the inner app event.
Message_Tag :: struct {
	values:     [^]cstring,
	values_len: uint,
}

// Full mirror of MarmotTimelineMessageRecord: records are indexed by
// value out of Timeline_Page, so the stride must match C exactly.
Timeline_Message_Record :: struct {
	message_id_hex:            cstring,
	source_message_id_hex:     cstring,
	has_source_epoch:          bool,
	source_epoch:              u64,
	has_retention_seconds:     bool,
	retention_seconds:         u64,
	has_retention_expires_at:  bool,
	retention_expires_at:      u64,
	direction:                 cstring,
	group_id_hex:              cstring,
	sender:                    cstring,
	plaintext:                 cstring,
	content_tokens:            Markdown_Document,
	kind:                      u64,
	tags:                      [^]Message_Tag,
	tags_len:                  uint,
	timeline_at:               u64,
	received_at:               u64,
	reply_to_message_id_hex:   cstring,
	reply_preview:             ^Timeline_Reply_Preview,
	media_json:                cstring,
	media:                     [^]Media_Attachment_Reference,
	media_len:                 uint,
	agent_text_stream_json:    cstring,
	group_system:              ^Group_System_Event, // kind-1210 only, else nil
	reactions:                 Timeline_Reaction_Summary,
	deleted:                   bool,
	deleted_by_message_id_hex: cstring,
	invalidation_status:       cstring,
}

Media_Locator :: struct {
	kind:  cstring,
	value: cstring,
}

// Also a borrowed input to send_media_reference / download_media.
Media_Attachment_Reference :: struct {
	locators:          [^]Media_Locator,
	locators_len:      uint,
	ciphertext_sha256: cstring,
	plaintext_sha256:  cstring,
	nonce_hex:         cstring,
	file_name:         cstring,
	media_type:        cstring,
	version:           i32, // MarmotEncryptedMediaVersion
	source_epoch:      u64,
	dim:               cstring,
	thumbhash:         cstring,
}

// Borrowed inputs to upload_media.
Media_Upload_Attachment_Request :: struct {
	file_name:     cstring,
	media_type:    cstring,
	plaintext:     [^]u8,
	plaintext_len: uint,
	dim:           cstring, // nullable
	thumbhash:     cstring, // nullable
}

Media_Upload_Request :: struct {
	attachments:     [^]Media_Upload_Attachment_Request,
	attachments_len: uint,
	caption:         cstring, // nullable
	send:            bool,
	blossom_server:  cstring, // nullable
}

Media_Upload_Attachment_Result :: struct {
	reference:            Media_Attachment_Reference,
	encrypted_size_bytes: u64,
}

Media_Upload_Result :: struct {
	attachments:     [^]Media_Upload_Attachment_Result,
	attachments_len: uint,
	sent:            ^Send_Summary,
}

Media_Download_Result :: struct {
	plaintext:     [^]u8,
	plaintext_len: uint,
	file_name:     cstring,
	media_type:    cstring,
	size_bytes:    u64,
}

Timeline_Page :: struct {
	messages:        [^]Timeline_Message_Record,
	messages_len:    uint,
	has_more_before: bool,
	has_more_after:  bool,
}

// Layout guards: sizes taken from sizeof() under gcc against the
// vendored marmot.h (x86_64). A mismatch means a mirror drifted from
// the C layout; fix the struct, then update the constant.
#assert(size_of(Timeline_Message_Record) == 288)
#assert(size_of(Group_System_Event) == 80)
#assert(size_of(Timeline_Page) == 24)
#assert(size_of(Timeline_Message_Query) == 72)
#assert(size_of(Send_Summary) == 32)
#assert(size_of(Chat_List_Row) == 208)
#assert(size_of(Markdown_Document) == 40)
#assert(size_of(Markdown_Block) == 56)
#assert(size_of(Markdown_Inline) == 48)
#assert(size_of(Markdown_List_Item) == 40)
#assert(size_of(Markdown_List_Kind) == 24)
#assert(size_of(Media_Attachment_Reference) == 88)
#assert(size_of(Media_Upload_Request) == 40)
#assert(size_of(Media_Upload_Attachment_Request) == 48)
#assert(size_of(Media_Upload_Result) == 24)
#assert(size_of(Media_Upload_Attachment_Result) == 96)
#assert(size_of(Media_Download_Result) == 40)

String_List :: struct {
	items: [^]cstring,
	len:   uint,
}

// KeyPackage prewarm counters for a prospective member set. Asked
// about a single member, a nonzero reused+network_resolved means that
// member has a KeyPackage to be invited with.
Member_Key_Package_Prewarm_Summary :: struct {
	requested_members:        u64,
	unique_members:           u64,
	reused_members:           u64,
	network_resolved_members: u64,
}

// One MLS key package the account owns: `local` = in the local store,
// `relay` = seen published, `source_relays` = where it was seen.
Account_Key_Package :: struct {
	account_ref:         cstring, // nullable: local account label
	account_id_hex:      cstring,
	key_package_id:      cstring,
	key_package_ref_hex: cstring,
	event_id_hex:        cstring,
	published_at:        u64,
	key_package_bytes:   u64,
	source_relays:       [^]cstring,
	source_relays_len:   uint,
	local:               bool,
	relay:               bool,
}

Account_Key_Package_List :: struct {
	items: [^]Account_Key_Package,
	len:   uint,
}

Group_Member_Record :: struct {
	member_id_hex: cstring,
	account:       cstring, // nullable: local account label
	local:         bool,
}

Group_Member_Details :: struct {
	member_id_hex: cstring,
	account:       cstring, // nullable
	local:         bool,
	is_admin:      bool,
	is_self:       bool,
	npub:          cstring,
	display_name:  cstring, // nullable
}

// Leading fields of the embedded MarmotAppGroupRecord, mirrored far
// enough to read the group's profile (name/description/avatar_url);
// the rest is padded to the record's 256-byte size.
Group_Record_Head :: struct {
	group_id_hex:       cstring,
	protocol_profile:   i32,
	endpoint:           cstring,
	profile_present:    bool,
	name:               cstring, // nullable
	description:        cstring, // nullable
	admins:             [^]cstring,
	admins_len:         uint,
	relays:             [^]cstring,
	relays_len:         uint,
	nostr_group_id_hex: cstring,
	avatar_url:         cstring, // nullable; wins over the Blossom image
	_mid:               [88]u8, // avatar_dim .. encrypted_media
	disappearing_message_secs: u64, // 0 = messages never expire
	_tail:              [64]u8, // archived .. via_welcome_message_id_hex
}

// Partial mirror of MarmotGroupDetails: the trailing mls_state is
// ignored. Reached by pointer only, freed by group_details_free.
// Offsets from offsetof() under gcc against the vendored marmot.h.
Group_Details :: struct {
	group:       Group_Record_Head, // embedded MarmotAppGroupRecord
	members:     [^]Group_Member_Details,
	members_len: uint,
	// mls_state tail ignored
}

#assert(size_of(Group_Member_Details) == 40)
#assert(offset_of(Group_Record_Head, description) == 40)
#assert(offset_of(Group_Record_Head, avatar_url) == 88)
#assert(offset_of(Group_Record_Head, disappearing_message_secs) == 184)
#assert(size_of(Group_Record_Head) == 256)
#assert(offset_of(Group_Details, members) == 256)
#assert(offset_of(Group_Details, members_len) == 264)

// Leading fields of MarmotAppGroupMlsState, mirrored far enough to
// read the epoch. Reached by pointer only, freed by
// app_group_mls_state_free.
Group_Mls_State_Head :: struct {
	group_id_hex:     cstring,
	protocol_profile: i32,
	lifecycle_state:  i32,
	epoch:            u64,
}

#assert(offset_of(Group_Mls_State_Head, epoch) == 16)

// One group's outcome from a retention sweep. Deferred statuses
// (unread, clock skew) mean MDK retries on a later sweep.
Retention_Sweep_Status :: enum i32 {
	NO_EXPIRED_MESSAGES,
	PRUNED,
	DEFERRED_CLOCK_SKEW,
	DEFERRED_UNREAD,
	DEFERRED_SCAN_EXHAUSTED,
	FAILED,
}

Retention_Sweep_Group_Outcome :: struct {
	group_id_hex:                cstring,
	status:                      Retention_Sweep_Status,
	pruned_messages:             u64,
	secrets_deleted:             u64,
	media_ciphertext_sha256:     [^]cstring, // blobs the caller may now delete
	media_ciphertext_sha256_len: uint,
	failure_kind:                cstring, // nullable
}

Retention_Sweep_Report :: struct {
	groups:     [^]Retention_Sweep_Group_Outcome,
	groups_len: uint,
}

#assert(offset_of(Retention_Sweep_Group_Outcome, status) == 8)
#assert(offset_of(Retention_Sweep_Group_Outcome, failure_kind) == 48)
#assert(size_of(Retention_Sweep_Group_Outcome) == 56)
#assert(size_of(Retention_Sweep_Report) == 16)

Group_Member_Record_List :: struct {
	items: [^]Group_Member_Record,
	len:   uint,
}

Account_Summary :: struct {
	label:            cstring,
	account_id_hex:   cstring,
	local_signing:    bool,
	external_signing: bool,
	signed_out:       bool,
	running:          bool,
}

Account_Summary_List :: struct {
	items: [^]Account_Summary,
	len:   uint,
}

// ── Observability: relay telemetry + audit logs ──────────────────────

Relay_Telemetry_Settings :: struct {
	export_enabled:          bool,
	export_interval_seconds: u64,
}

// OTLP route for the telemetry exporter. Borrowed input.
Relay_Telemetry_Resource :: struct {
	service_version:         cstring,
	service_instance_id:     cstring,
	deployment_environment:  cstring,
	tenant:                  cstring,
	os_type:                 cstring,
	os_version:              cstring,
	device_model_identifier: cstring,
}

Relay_Telemetry_Runtime_Config :: struct {
	otlp_endpoint:              cstring,
	authorization_bearer_token: cstring,
	resource:                   ^Relay_Telemetry_Resource,
}

// Audit-log content posture; the default keeps identifiers hashed.
Audit_Data_Mode :: enum i32 {
	OBFUSCATED_SENSITIVE_DATA,
	FULL_DATA,
}

Audit_Log_Settings :: struct {
	enabled:   bool,
	data_mode: Audit_Data_Mode,
}

Audit_Log_File :: struct {
	account_ref:        cstring,
	path:               cstring,
	file_name:          cstring,
	size_bytes:         u64,
	has_modified_at_ms: bool,
	modified_at_ms:     u64,
}

Audit_Log_File_List :: struct {
	items: [^]Audit_Log_File,
	len:   uint,
}

// still_recording: the deleted file was live and the recorder rotated
// into a fresh one, rather than the file simply being removed.
Audit_Log_Delete_Result :: struct {
	still_recording: bool,
}

Audit_Log_Upload_Source :: struct {
	device_label: cstring,
	platform:     cstring,
	app_version:  cstring,
}

Audit_Log_Tracker_Config :: struct {
	endpoint:                   cstring,
	authorization_bearer_token: cstring,
	source:                     Audit_Log_Upload_Source,
}

@(default_calling_convention = "c", link_prefix = "marmot_")
foreign lib {
	client_new         :: proc(root_path: cstring, relay_urls: [^]cstring, relay_urls_len: uint, out_client: ^^Client) -> Status ---
	client_new_with_secret_store :: proc(root_path: cstring, relay_urls: [^]cstring, relay_urls_len: uint, store: ^Secret_Store, out_client: ^^Client) -> Status ---
	client_start       :: proc(client: ^Client) -> Status ---
	client_shutdown    :: proc(client: ^Client) -> Status ---
	client_free        :: proc(client: ^Client) ---

	// Thread-local detail for the most recent failure; free with string_free.
	last_error_message :: proc() -> cstring ---
	string_free        :: proc(s: cstring) ---

	list_accounts             :: proc(client: ^Client, out: ^^Account_Summary_List) -> Status ---
	account_summary_free      :: proc(ptr: ^Account_Summary) ---
	account_summary_list_free :: proc(list: ^Account_Summary_List) ---

	sign_in_account :: proc(client: ^Client, account_ref: cstring, out: ^^Account_Summary) -> Status ---
	sign_out        :: proc(client: ^Client, account_ref: cstring, delete_key_packages: bool, out: ^^Sign_Out_Outcome) -> Status ---
	sign_out_outcome_free :: proc(ptr: ^Sign_Out_Outcome) ---

	set_account_nip65_relays :: proc(client: ^Client, account_ref: cstring, relays: [^]cstring, relays_len: uint, bootstrap_relays: [^]cstring, bootstrap_relays_len: uint, out: ^^Account_Relay_Lists) -> Status ---
	set_account_inbox_relays :: proc(client: ^Client, account_ref: cstring, relays: [^]cstring, relays_len: uint, bootstrap_relays: [^]cstring, bootstrap_relays_len: uint, out: ^^Account_Relay_Lists) -> Status ---
	publish_relay_lists      :: proc(client: ^Client, account_ref: cstring, default_relays: [^]cstring, default_relays_len: uint, bootstrap_relays: [^]cstring, bootstrap_relays_len: uint) -> Status ---
	account_relay_lists_free :: proc(ptr: ^Account_Relay_Lists) ---

	relay_health      :: proc(client: ^Client, out: ^^Relay_Health) -> Status ---
	relay_health_free :: proc(ptr: ^Relay_Health) ---

	// Observability. The *_settings pairs gate whether anything is
	// recorded or sent; the *_config calls only say where it would go.
	relay_telemetry_settings           :: proc(client: ^Client, out: ^^Relay_Telemetry_Settings) -> Status ---
	set_relay_telemetry_settings       :: proc(client: ^Client, settings: ^Relay_Telemetry_Settings, out: ^^Relay_Telemetry_Settings) -> Status ---
	set_relay_telemetry_runtime_config :: proc(client: ^Client, config: ^Relay_Telemetry_Runtime_Config) -> Status ---
	relay_telemetry_settings_free      :: proc(ptr: ^Relay_Telemetry_Settings) ---
	telemetry_install_id               :: proc(client: ^Client, out: ^cstring) -> Status ---

	audit_log_settings           :: proc(client: ^Client, out: ^^Audit_Log_Settings) -> Status ---
	set_audit_log_settings       :: proc(client: ^Client, settings: ^Audit_Log_Settings, out: ^^Audit_Log_Settings) -> Status ---
	audit_log_settings_free      :: proc(ptr: ^Audit_Log_Settings) ---
	set_audit_log_tracker_config :: proc(client: ^Client, config: ^Audit_Log_Tracker_Config, out: ^^Audit_Log_Tracker_Config) -> Status ---
	audit_log_tracker_config_free :: proc(ptr: ^Audit_Log_Tracker_Config) ---

	audit_log_files            :: proc(client: ^Client, out: ^^Audit_Log_File_List) -> Status ---
	audit_log_file_list_free   :: proc(list: ^Audit_Log_File_List) ---
	delete_audit_log_file      :: proc(client: ^Client, path: cstring, out: ^^Audit_Log_Delete_Result) -> Status ---
	audit_log_delete_result_free :: proc(ptr: ^Audit_Log_Delete_Result) ---

	publish_user_profile      :: proc(client: ^Client, account_ref: cstring, profile: ^User_Profile_Metadata, default_relays: [^]cstring, default_relays_len: uint, bootstrap_relays: [^]cstring, bootstrap_relays_len: uint, out: ^^User_Profile_Metadata) -> Status ---
	user_profile_metadata_free :: proc(ptr: ^User_Profile_Metadata) ---

	// NIP-02 follow list. follow/unfollow publish the updated list and
	// write the new follow set.
	account_follows :: proc(client: ^Client, account_ref: cstring, out: ^^String_List) -> Status ---
	unfollow_user   :: proc(client: ^Client, account_ref: cstring, user_ref: cstring, out: ^^String_List) -> Status ---

	// Resolve and cache KeyPackages for prospective members. Asked
	// about one member, the counters answer whether that member has a
	// KeyPackage anyone could invite them with.
	prewarm_group_member_key_packages         :: proc(client: ^Client, account_ref: cstring, member_refs: [^]cstring, member_refs_len: uint, out: ^^Member_Key_Package_Prewarm_Summary) -> Status ---
	member_key_package_prewarm_summary_free   :: proc(ptr: ^Member_Key_Package_Prewarm_Summary) ---

	// Cached kind-0 profile for an account id; out may be NULL with OK.
	user_profile :: proc(client: ^Client, account_id_hex: cstring, out: ^^User_Profile_Metadata) -> Status ---

	// Repopulate that cache for one account id from `relays`. Blocks
	// on the relay round trip.
	refresh_profile :: proc(client: ^Client, account_id_hex: cstring, relays: [^]cstring, relays_len: uint) -> Status ---

	// Any account's published relay lists, keyed by account id rather
	// than a local account: the cached read never touches the network,
	// the refresh fetches from `relays` and updates the cache. An
	// account that has published nothing reports both kinds in
	// `missing` rather than failing. Free with account_relay_lists_free.
	user_relay_lists         :: proc(client: ^Client, account_id_hex: cstring, out: ^^Account_Relay_Lists) -> Status ---
	refresh_user_relay_lists :: proc(client: ^Client, account_id_hex: cstring, relays: [^]cstring, relays_len: uint, out: ^^Account_Relay_Lists) -> Status ---

	// Directory/profile lookups; out strings may be NULL with OK.
	npub         :: proc(client: ^Client, account_id_hex: cstring, out: ^cstring) -> Status ---
	// Hex id for an npub/hex reference; out may be NULL with OK when the
	// input does not decode.
	account_id_hex :: proc(client: ^Client, reference: cstring, out: ^cstring) -> Status ---
	display_name :: proc(client: ^Client, account_id_hex: cstring, out: ^cstring) -> Status ---
	reveal_nsec  :: proc(client: ^Client, account_ref: cstring, out: ^cstring) -> Status ---

	// SENSITIVE: reveal_nsec marks the account key handled-insecurely;
	// the encrypted export seals under `passphrase` (NIP-49) instead.
	export_encrypted_secret_key :: proc(client: ^Client, account_ref: cstring, passphrase: cstring, out: ^cstring) -> Status ---

	// Key-package state and publishing. `out` takes the accepting-relay
	// count; republish reuses the cached package, publish_new mints one.
	account_key_packages          :: proc(client: ^Client, account_ref: cstring, bootstrap_relays: [^]cstring, bootstrap_relays_len: uint, out: ^^Account_Key_Package_List) -> Status ---
	account_key_package_list_free :: proc(list: ^Account_Key_Package_List) ---
	publish_new_key_package       :: proc(client: ^Client, account_ref: cstring, out: ^u64) -> Status ---
	republish_key_package         :: proc(client: ^Client, account_ref: cstring, out: ^u64) -> Status ---

	account_nip65_relays :: proc(client: ^Client, account_ref: cstring, out: ^^String_List) -> Status ---
	account_inbox_relays :: proc(client: ^Client, account_ref: cstring, out: ^^String_List) -> Status ---
	string_list_free     :: proc(list: ^String_List) ---

	group_members                     :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, out: ^^Group_Member_Record_List) -> Status ---
	group_details                     :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, out: ^^Group_Details) -> Status ---
	group_details_free                :: proc(ptr: ^Group_Details) ---
	group_mls_state                   :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, out: ^^Group_Mls_State_Head) -> Status ---
	app_group_mls_state_free          :: proc(ptr: ^Group_Mls_State_Head) ---

	invite_members :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, member_refs: [^]cstring, member_refs_len: uint, out: ^^Send_Summary) -> Status ---
	remove_members :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, member_refs: [^]cstring, member_refs_len: uint, out: ^^Send_Summary) -> Status ---
	promote_admin  :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, member_ref: cstring, out: ^^Send_Summary) -> Status ---
	demote_admin   :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, member_ref: cstring, out: ^^Send_Summary) -> Status ---
	app_group_member_record_list_free :: proc(list: ^Group_Member_Record_List) ---

	// Blocking-next subscription to the account's chat-list projection;
	// timeout_ms 0 waits forever, shutdown yields CLOSED.
	subscribe_chat_list         :: proc(client: ^Client, account_ref: cstring, include_archived: bool, out_sub: ^^Chat_List_Subscription) -> Status ---
	chat_list_subscription_next :: proc(sub: ^Chat_List_Subscription, timeout_ms: u32, out: ^^Chat_List_Row) -> Status ---
	chat_list_subscription_free :: proc(sub: ^Chat_List_Subscription) ---

	create_group      :: proc(client: ^Client, account_ref: cstring, name: cstring, member_refs: [^]cstring, member_refs_len: uint, description: cstring, out: ^cstring) -> Status ---
	send_text         :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, text: cstring, out: ^^Send_Summary) -> Status ---
	// App-defined event: any non-reserved kind with caller-built tags
	// (borrowed, MarmotStringArray rows == Message_Tag layout). Carries
	// NIP-88 polls/votes and thread messages.
	send_custom_event :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, kind: u64, tags: [^]Message_Tag, tags_len: uint, content: cstring, out: ^^Send_Summary) -> Status ---
	// An imeta tag for an uploaded reference, so a custom event can
	// carry media the timeline resolves like a kind-9's.
	build_media_imeta_tag :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, reference: ^Media_Attachment_Reference, out: ^^Message_Tag) -> Status ---
	message_tag_free      :: proc(tag: ^Message_Tag) ---
	react_to_message  :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, target_message_id: cstring, emoji: cstring, out: ^^Send_Summary) -> Status ---
	unreact_from_message :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, target_message_id: cstring, out: ^^Send_Summary) -> Status ---
	reply_to_message     :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, target_message_id: cstring, text: cstring, out: ^^Send_Summary) -> Status ---

	set_group_archived         :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, archived: bool, out: ^^App_Group_Record) -> Status ---
	leave_group                :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, out: ^^Send_Summary) -> Status ---
	accept_group_invite        :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, out: ^^App_Group_Record) -> Status ---
	decline_group_invite       :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, out: ^^Group_Invite_Decline_Result) -> Status ---
	update_group_profile       :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, name: cstring, description: cstring, out: ^^Send_Summary) -> Status ---
	update_message_retention   :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, disappearing_message_secs: u64, out: ^^Send_Summary) -> Status ---
	sweep_expired_retention    :: proc(client: ^Client, account_ref: cstring, now_ms: u64, out: ^^Retention_Sweep_Report) -> Status ---
	retention_sweep_report_free :: proc(ptr: ^Retention_Sweep_Report) ---
	update_group_avatar_url    :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, url: cstring, dim: cstring, thumbhash: cstring, out: ^^Send_Summary) -> Status ---

	// Encrypted-Blossom group avatar: update_group_image encrypts and
	// uploads the raw bytes then commits them (admin only), download
	// fetches and decrypts the committed one. Free the buffer with
	// bytes_free.
	update_group_image             :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, plaintext: [^]u8, plaintext_len: uint, media_type: cstring, out: ^^Send_Summary) -> Status ---
	download_group_blossom_image   :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, out_data: ^[^]u8, out_len: ^uint) -> Status ---
	bytes_free                     :: proc(data: [^]u8, len: uint) ---
	mark_timeline_message_read :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, message_id_hex: cstring, out: ^^Chat_List_Row) -> Status ---

	app_group_record_free            :: proc(ptr: ^App_Group_Record) ---
	group_invite_decline_result_free :: proc(ptr: ^Group_Invite_Decline_Result) ---
	edit_message      :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, target_message_id: cstring, content: cstring, out: ^^Send_Summary) -> Status ---
	delete_message    :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, target_message_id: cstring, out: ^^Send_Summary) -> Status ---
	send_summary_free :: proc(ptr: ^Send_Summary) ---

	upload_media               :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, request: ^Media_Upload_Request, out: ^^Media_Upload_Result) -> Status ---
	upload_profile_image       :: proc(client: ^Client, account_ref: cstring, data: [^]u8, data_len: uint, media_type: cstring, blossom_server: cstring, out: ^cstring) -> Status ---
	media_upload_result_free   :: proc(ptr: ^Media_Upload_Result) ---
	download_media             :: proc(client: ^Client, account_ref: cstring, group_id_hex: cstring, reference: ^Media_Attachment_Reference, out: ^^Media_Download_Result) -> Status ---
	media_download_result_free :: proc(ptr: ^Media_Download_Result) ---

	timeline_messages  :: proc(client: ^Client, account_ref: cstring, query: ^Timeline_Message_Query, out: ^^Timeline_Page) -> Status ---
	timeline_page_free :: proc(ptr: ^Timeline_Page) ---

	parse_markdown         :: proc(client: ^Client, text: cstring, out: ^^Markdown_Document) -> Status ---
	markdown_document_free :: proc(ptr: ^Markdown_Document) ---

	chat_list               :: proc(client: ^Client, account_ref: cstring, include_archived: bool, out: ^^Chat_List_Row_List) -> Status ---
	chat_list_row_free      :: proc(ptr: ^Chat_List_Row) ---
	chat_list_row_list_free :: proc(list: ^Chat_List_Row_List) ---

	create_identity :: proc(client: ^Client, default_relays: [^]cstring, default_relays_len: uint, bootstrap_relays: [^]cstring, bootstrap_relays_len: uint, out: ^^Account_Summary) -> Status ---
	login           :: proc(client: ^Client, identity: cstring, default_relays: [^]cstring, default_relays_len: uint, bootstrap_relays: [^]cstring, bootstrap_relays_len: uint, out: ^^Account_Summary) -> Status ---
}

// Copy the thread-local error detail into an Odin string and release
// the C allocation. Returns "" when there is no detail.
last_error :: proc() -> string {
	msg := last_error_message()
	if msg == nil {
		return ""
	}
	s := string(msg)
	out := make([]u8, len(s))
	copy(out, s)
	string_free(msg)
	return string(out)
}
