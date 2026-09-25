package main

import marmot "../marmot"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

@(private)
Issue_Work :: struct {
	mutex:                    sync.Mutex,
	worker:                   ^thread.Thread,
	client:                   ^marmot.Client,
	account, group:           cstring,
	cancel, requested, ready: bool,
	setting:                  Issue_Setting,
	admin:                    bool,
	records:                  ^marmot.App_Message_List,
	err:                      string,
}
@(private)
issue_job: ^Issue_Work
@(private)
issue_retired: [dynamic]^Issue_Work
@(private)
issue_page: ^marmot.App_Message_List

@(private)
issues_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	job := (^Issue_Work)(t.data)
	for {
		sync.lock(&job.mutex)
		cancel, requested := job.cancel, job.requested
		job.requested = false
		sync.unlock(&job.mutex)
		if cancel {return}
		if !requested {time.sleep(100 * time.Millisecond); continue}
		component: ^marmot.Group_App_Component
		records: ^marmot.App_Message_List
		details: ^marmot.Group_Details
		setting := Issue_Setting.Unavailable
		admin := false
		status := marmot.group_app_component(
			job.client,
			job.account,
			job.group,
			ISSUE_COMPONENT,
			&component,
		)
		if status == .OK {
			setting = .Disabled
			if component != nil {
				setting = issue_setting(component.data[:component.data_len])
				marmot.group_app_component_free(component)
			}
			status = marmot.group_details(job.client, job.account, job.group, &details)
			if status == .OK {
				for i in 0 ..< details.members_len {
					member := &details.members[i]
					if member.is_self {admin = member.is_admin}
				}
				marmot.group_details_free(details)
				// MDK retains disabled history; load it when the tracker is enabled.
				if setting == .Enabled {
					kinds := ISSUE_KINDS
					status = marmot.messages(
						job.client,
						job.account,
						job.group,
						0,
						0,
						raw_data(kinds[:]),
						len(ISSUE_KINDS),
						&records,
					)
				}
			}
		}
		err: string
		if status != .OK {
			err = marmot.last_error()
			if err == "" {err = strings.clone("Issue history unavailable.")}
			setting = .Unavailable
		}
		sync.lock(&job.mutex)
		if job.records != nil {marmot.app_message_list_free(job.records)}
		delete(job.err)
		job.records, job.err, job.setting, job.admin, job.ready =
			records, err, setting, admin, true
		sync.unlock(&job.mutex)
		frame_wake()
		free_all(context.temp_allocator)
	}
}

@(private)
issues_refresh :: proc() {
	if issue_job == nil {return}
	sync.lock(&issue_job.mutex)
	issue_job.requested = true
	sync.unlock(&issue_job.mutex)
}

@(private)
issues_retire :: proc(ui: ^Ui_State) {
	if issue_job != nil {
		sync.lock(&issue_job.mutex)
		issue_job.cancel = true
		sync.unlock(&issue_job.mutex)
		append(&issue_retired, issue_job)
		issue_job = nil
	}
	issues_rows_free(ui.issues, ui.issue_index)
	ui.issues, ui.issue_index = {}, nil
	if issue_page != nil {marmot.app_message_list_free(issue_page); issue_page = nil}
	ui.issue_setting, ui.issue_admin, ui.issues_open = .Unavailable, false, false
	delete(ui.issue_selected); ui.issue_selected = ""
	clear(
		&ui.issue_subject,
	); clear(&ui.issue_body); clear(&ui.issue_labels); clear(&ui.issue_search)
	ui.issue_new = false
	ui.issue_filter_open = false
	ui.issue_ticket = 0
	blocks_free(ui.issue_blocks); ui.issue_blocks = {}
}

@(private)
issues_free :: proc(job: ^Issue_Work) {
	thread.join(job.worker)
	thread.destroy(job.worker)
	if job.records != nil {marmot.app_message_list_free(job.records)}
	delete(job.account); delete(job.group); delete(job.err)
	free(job)
}

@(private)
issues_drain :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	for i := len(issue_retired) - 1; i >= 0; i -= 1 {
		if thread.is_done(
			issue_retired[i].worker,
		) {issues_free(issue_retired[i]); unordered_remove(&issue_retired, i)}
	}
	group := ui.selected >= 0 ? ui.chats[ui.selected].group_id : ""
	if issue_job != nil &&
	   (string(issue_job.account) != ui.account_ref ||
			   string(issue_job.group) != group) {issues_retire(ui)}
	if client == nil || group == "" {return}
	if issue_job == nil {
		job := new(Issue_Work)
		job.client, job.account, job.group =
			client, strings.clone_to_cstring(ui.account_ref), strings.clone_to_cstring(group)
		job.requested = true
		job.worker = thread.create(issues_worker)
		job.worker.data = job
		issue_job = job
		thread.start(job.worker)
	}
	job := issue_job
	sync.lock(&job.mutex)
	ready, page, setting, admin, err := job.ready, job.records, job.setting, job.admin, job.err
	job.ready, job.records, job.err = false, nil, ""
	sync.unlock(&job.mutex)
	if !ready {return}
	defer delete(err)
	ui.issue_setting, ui.issue_admin = setting, admin
	if setting != .Enabled {ui.issues_open = false; issues_sync_route(ui, client)}
	if err != "" {ui.client_status = strings.clone(tr("Couldn't load issues. Please try again."))}
	if page == nil {
		issues_rows_free(ui.issues, ui.issue_index)
		ui.issues, ui.issue_index = {}, nil
		if issue_page != nil {marmot.app_message_list_free(issue_page); issue_page = nil}
		blocks_free(ui.issue_blocks); ui.issue_blocks = {}
		return
	}
	issues_rows_free(ui.issues, ui.issue_index)
	if issue_page != nil {marmot.app_message_list_free(issue_page)}
	issue_page = page
	ui.issues, ui.issue_index = issues_project(
		page.items[:page.len],
		group,
		u64(time.time_to_unix(time.now())),
	)
	issues_select(ui, client, ui.issue_selected)
	if timeline_page != nil {timeline_apply(client, ui, timeline_page)}
}

@(private)
issues_stop :: proc(ui: ^Ui_State) {
	issues_retire(ui)
	for job in issue_retired {issues_free(job)}
	delete(issue_retired); issue_retired = {}
}
