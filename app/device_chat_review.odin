package main

import marmot "../marmot"
import "core:slice"
import "core:sync"

@(private)
Device_Chat_Blocker :: enum {
	Ready,
	Needs_Admin,
	Waiting_For_Support,
	Replacement,
	Activation_Limit,
	Unsupported,
	No_Relays,
	Account_Limit,
}

@(private)
Device_Chat_Block :: struct {
	index:   uint,
	blocker: Device_Chat_Blocker,
}

@(private)
Device_Chat_Review :: struct {
	chats:      ^marmot.Presented_Chat_List,
	rows:       [dynamic]Device_Chat_Block,
	incomplete: bool,
}

@(private)
device_read_chat_review :: proc(
	client: ^marmot.Client,
	account: cstring,
	review: ^Device_Chat_Review,
	cancel: ^bool,
) -> marmot.Status {
	status := marmot.presented_chat_list(client, account, true, &review.chats)
	if status != .OK || review.chats == nil {return status}
	for row, i in review.chats.rows[:review.chats.rows_len] {
		if sync.atomic_load(cancel) {return .OK}
		if row.row.pending_confirmation ||
		   row.row.self_membership != .MEMBER ||
		   row.row.disbanding ||
		   row.row.lifecycle_state == .DISBANDED ||
		   row.row.lifecycle_state == .UNRECOVERABLE {continue}
		blocker, blocked, checked := device_chat_blocker(client, account, row.row.group_id_hex)
		if blocked {append(&review.rows, Device_Chat_Block{uint(i), blocker})}
		if !checked {review.incomplete = true}
	}
	slice.sort_by(review.rows[:], proc(a, b: Device_Chat_Block) -> bool {
		return a.blocker < b.blocker || (a.blocker == b.blocker && a.index < b.index)
	})
	return .OK
}

@(private = "file")
device_chat_blocker :: proc(
	client: ^marmot.Client,
	account, group: cstring,
) -> (
	blocker: Device_Chat_Blocker,
	blocked, checked: bool,
) {
	ACCOUNT_DEVICES_COMPONENT :: 0x800d
	MAX_LEAVES_PER_ACCOUNT :: 20
	details: ^marmot.Group_Details
	if marmot.group_details(client, account, group, &details) != .OK || details == nil {return}
	defer marmot.group_details_free(details)
	if details.mls_state.unrecoverable || details.mls_state.lifecycle_state == .DISBANDED {
		return {}, false, true
	}
	for component in details.mls_state.required_app_components[:details.mls_state.required_app_components_len] {
		if component != ACCOUNT_DEVICES_COMPONENT {continue}
		if details.group.relays_len == 0 {return .No_Relays, true, true}
		for member in details.members[:details.members_len] {
			if member.is_self && member.device_count >= MAX_LEAVES_PER_ACCOUNT {
				return .Account_Limit, true, true
			}
		}
		return {}, false, true
	}
	activation: marmot.Account_Devices_Activation
	if marmot.account_devices_activation(client, account, group, &activation) != .OK {return}
	switch activation {
	case .ELIGIBLE:
		return .Ready, true, true
	case .NOT_ADMIN:
		return .Needs_Admin, true, true
	case .MEMBERS_NEED_UPDATE:
		return .Waiting_For_Support, true, true
	case .DEVICES_NEED_REPLACEMENT:
		return .Replacement, true, true
	case .DEVICE_LIMIT_EXCEEDED:
		return .Activation_Limit, true, true
	case .LEGACY_GROUP:
		return .Unsupported, true, true
	case .ALREADY_ENABLED:
		return {}, false, true
	}
	return
}
