package main

import "nendo"

settings_notifications :: proc(ui: ^Ui_State) {
	desktop := ui.prefs.notify_desktop
	dependent: Settings_Control_State = desktop ? .Enabled : .Disabled
	row := nendo.Box {
		width = nendo.grow(),
	}
	settings_group(tr("Desktop alerts"))
	if nendo.box(nendo.id("NotificationsGroup"))(settings_box()) {
		if nendo.box(nendo.id("RowNotify"))(row) {
			settings_check(
				"TgNotify",
				desktop,
				tr("Desktop notifications"),
				tr("Get an alert when a message arrives in a chat you're not viewing."),
			)
		}
		settings_divider()
		if nendo.box(nendo.id("RowSound"))(row) {
			settings_check(
				"TgSound",
				ui.prefs.notify_sound,
				tr("Desktop alert sound"),
				"",
				dependent,
			)
		}
		settings_divider()
		if nendo.box(nendo.id("RowPreview"))(row) {
			settings_check(
				"TgPreview",
				ui.prefs.notify_preview,
				tr("Message previews"),
				tr("Off shows only \"New message\" without the text."),
				dependent,
			)
		}
		settings_divider()
		if nendo.box(nendo.id("RowNotifyTest"))(
		{width = nendo.grow(), direction = .Column, gap = 4},
		) {
			enabled := notify_test_enabled(ui)
			if nendo.box(nendo.id_local("TestControls"))(settings_line()) {
				row_labels(
					tr("Send a test notification"),
					tr("Uses your current sound and preview settings."),
				)
				settings_nav_button(
					"NotifyTest",
					tr("Send test"),
					state = enabled ? .Enabled : .Disabled,
				)
			}
			if !desktop {
				nendo.text(
					tr("Turn on desktop notifications to change these options or send a test."),
					{font = FONT_BODY, size = 11, color = TEXT_DIM},
				)
			}
			if notify_test_pending {
				nendo.text(
					tr("Sending a test notification..."),
					{font = FONT_BODY, size = 11, color = TEXT_DIM},
				)
				busy_bar("NotifyTestBusy")
			} else {
				label := ""
				#partial switch notify_test_result {
				case .Accepted:
					label = tr(
						"The notification service accepted the test. Check your system notifications.",
					)
				case .Failed:
					label = tr(
						"Couldn't send the test notification. Check your system notification settings and try again.",
					)
				case .Unconfirmed:
					label = tr("Check your system notifications for the test alert.")
				}
				if label != "" {
					nendo.text(
						label,
						{
							font = FONT_BODY,
							size = 11,
							color = notify_test_result == .Failed ? DANGER : TEXT_DIM,
						},
					)
				}
			}
		}
	}
	settings_group(tr("In-app sounds"))
	if nendo.box(nendo.id("InterfaceSoundsGroup"))(settings_box()) {
		if nendo.box(nendo.id("RowUiSounds"))(row) {
			settings_check(
				"TgUiSounds",
				ui.prefs.ui_sounds,
				tr("Message tones"),
				tr("Short tones when a message leaves, arrives, or fails to send."),
			)
		}
	}
}
