// Profile picture upload: a picked file goes to public Blossom
// (marmot_upload_profile_image), then kind-0 republishes carrying the
// new URL with every other field preserved. Both are relay round
// trips, so a one-shot thread runs them; drain_ppic hands the URL back
// to the frame loop, which owns texture creation.
//
//   pick → photo preview → Use → ppic_worker (upload +
//   publish) → drain_ppic (round texture + my_pic_url)
package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

import rl "sdlrl"

import marmot "../marmot"

@(private = "file")
Ppic_Job :: struct {
	client:     ^marmot.Client,
	account:    string,
	data:       []u8,
	media_type: string, // static literal from media_type_for
}

// One upload in flight at a time; the pane greys the button off this.
ppic_busy: bool

@(private = "file")
ppic_mutex: sync.Mutex
@(private = "file")
ppic_job: Ppic_Job
@(private = "file")
ppic_url: string // "" on failure
@(private = "file")
ppic_err: string
@(private = "file")
ppic_ready: bool

// Use has revalidated the captured account and busy state. Takes the draft.
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
	job := ppic_job
	account := strings.clone_to_cstring(job.account, context.temp_allocator)
	media := strings.clone_to_cstring(job.media_type, context.temp_allocator)
	url, err: string

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
		marmot.string_free(url_c)
	} else {
		err = fmt.aprintf(tr("Couldn't upload the picture. %s"), marmot.last_error())
	}

	// Republish kind-0 with the new URL, everything else as it stands.
	if len(url) > 0 {
		metadata: marmot.User_Profile_Metadata
		cur: ^marmot.User_Profile_Metadata
		if marmot.user_profile(job.client, account, &cur) == .OK && cur != nil {
			metadata = cur^
		}
		metadata.picture = strings.clone_to_cstring(url, context.temp_allocator)

		out: ^marmot.User_Profile_Metadata
		if marmot.publish_user_profile(
			   job.client,
			   account,
			   &metadata,
			   raw_data(DEFAULT_RELAYS),
			   uint(len(DEFAULT_RELAYS)),
			   raw_data(DEFAULT_RELAYS),
			   uint(len(DEFAULT_RELAYS)),
			   &out,
		   ) !=
		   .OK {
			err = fmt.aprintf(tr("Couldn't publish the picture. %s"), marmot.last_error())
			delete(url)
			url = ""
		} else {
			marmot.user_profile_metadata_free(out)
		}
		if cur != nil {
			marmot.user_profile_metadata_free(cur)
		}
	}
	free_all(context.temp_allocator)

	sync.lock(&ppic_mutex)
	ppic_url = url
	ppic_err = err
	ppic_ready = true
	sync.unlock(&ppic_mutex)
}

// Frame-loop drain: register the uploaded picture under its Blossom
// URL (same bytes, saves the re-download) and adopt it as my_pic_url.
drain_ppic :: proc(ui: ^Ui_State) {
	sync.lock(&ppic_mutex)
	ready := ppic_ready
	url := ppic_url
	err := ppic_err
	ppic_ready = false
	sync.unlock(&ppic_mutex)
	if !ready {
		return
	}

	if len(err) > 0 {
		set_status(ui, err, .Error)
	}
	if len(url) > 0 {
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
