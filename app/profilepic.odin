// Profile picture upload: a picked file goes to public Blossom
// (marmot_upload_profile_image), then kind-0 republishes carrying the
// new URL with every other field preserved. Both are relay round
// trips, so a one-shot thread runs them; drain_ppic hands the URL back
// to the frame loop, which owns texture creation.
package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

import rl "sdlrl"

import marmot "../marmot"

@(private = "file")
Ppic_Result :: enum {
	None,
	Published,
	Upload_Failed,
	Publish_Failed,
}

@(private = "file")
Ppic_Job :: struct {
	client:     ^marmot.Client,
	account:    string,
	data:       []u8,
	media_type: string, // static literal from media_type_for
}

// Only the frame thread reads the owner or starts another upload.
ppic_busy: bool

@(private)
profile_pic_owner :: proc() -> string {
	return ppic_job.account
}

@(private = "file")
ppic_mutex: sync.Mutex
@(private = "file")
ppic_job: Ppic_Job
@(private = "file")
ppic_url: string // "" on failure
@(private = "file")
ppic_result: Ppic_Result

// The preview has revalidated the captured account and busy state. Takes the draft.
@(private)
upload_profile_pic :: proc(client: ^marmot.Client, account: string, draft: Pic_Draft) {
	rl.UnloadImage(draft.image)
	ppic_busy = true
	ppic_job = {
		client     = client,
		account    = strings.clone(account),
		data       = draft.data,
		media_type = draft.media_type,
	}
	append(&send_threads, thread.create_and_start(ppic_worker))
}

@(private = "file")
ppic_worker :: proc() {
	context.allocator = reload_allocator()
	defer frame_wake()
	job := ppic_job
	account := strings.clone_to_cstring(job.account, context.temp_allocator)
	media := strings.clone_to_cstring(job.media_type, context.temp_allocator)
	url: string
	result := Ppic_Result.Upload_Failed

	url_c: cstring
	if marmot.upload_profile_image(
		   job.client,
		   account,
		   raw_data(job.data),
		   uint(len(job.data)),
		   media,
		   nil,
		   &url_c,
	   ) ==
		   .OK &&
	   url_c != nil {
		url = strings.clone(string(url_c))
	}
	if url_c != nil {
		marmot.string_free(url_c)
	}

	// Republish kind-0 with the new URL, everything else as it stands.
	if len(url) > 0 {
		result = .Publish_Failed
		metadata: marmot.User_Profile_Metadata
		cur: ^marmot.User_Profile_Metadata
		if marmot.user_profile(job.client, account, &cur) == .OK {
			if cur != nil {
				metadata = cur^
			}
			metadata.picture = strings.clone_to_cstring(url, context.temp_allocator)
			out: ^marmot.User_Profile_Metadata
			if marmot.publish_user_profile(
				   job.client,
				   account,
				   &metadata,
				   raw_data(DEFAULT_RELAYS),
				   len(DEFAULT_RELAYS),
				   raw_data(DEFAULT_RELAYS),
				   len(DEFAULT_RELAYS),
				   &out,
			   ) ==
			   .OK {
				result = .Published
			}
			if out != nil {
				marmot.user_profile_metadata_free(out)
			}
		}
		if result != .Published {
			delete(url)
			url = ""
		}
		if cur != nil {
			marmot.user_profile_metadata_free(cur)
		}
	}
	free_all(context.temp_allocator)

	sync.lock(&ppic_mutex)
	ppic_url = url
	ppic_result = result
	sync.unlock(&ppic_mutex)
}

// Frame-loop drain: register the uploaded picture under its Blossom
// URL (same bytes, saves the re-download) and adopt it as my_pic_url.
drain_ppic :: proc(ui: ^Ui_State) {
	sync.lock(&ppic_mutex)
	result := ppic_result
	url := ppic_url
	ppic_result, ppic_url = .None, ""
	sync.unlock(&ppic_mutex)
	if result == .None {
		return
	}

	if result == .Published {
		ext := strings.clone_to_cstring(
			fmt.tprintf(".%s", strings.trim_prefix(ppic_job.media_type, "image/")),
			context.temp_allocator,
		)
		image := rl.LoadImageFromMemory(ext, raw_data(ppic_job.data), i32(len(ppic_job.data)))
		if image.data != nil {
			register_local_pic(url, image)
			rl.UnloadImage(image)
		}
		adopt_profile_pic(ui, ppic_job.account, url)
	}

	label: string
	kind := Status_Kind.Error
	switch result {
	case .None:
	case .Published:
		label, kind = tr("Picture published to your profile."), .Info
	case .Upload_Failed:
		label = tr("Couldn't upload the picture. Please try again.")
	case .Publish_Failed:
		label = tr(
			"Couldn't confirm picture publication. Your picture was uploaded. Please try again.",
		)
	}
	delete(ui.profile_pic_notice)
	ui.profile_pic_notice = fmt.aprintf("%s · %s", account_label(ui, ppic_job.account), label)
	ui.profile_pic_notice_kind = kind

	delete(ppic_job.data)
	delete(ppic_job.account)
	ppic_job = {}
	ppic_busy = false
}

// The result belongs to the submitting account, not the currently open pane.
// Cache registration remains useful across switches, but URL ownership does not.
@(private)
adopt_profile_pic :: proc(ui: ^Ui_State, account, url: string) {
	if ui.account_ref == account && !account_departing(account) {
		ui.my_pic_url = url
		ui.profile.pic_set = true
	} else {
		delete(url)
	}
}
