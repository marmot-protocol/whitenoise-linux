package main

import "core:fmt"

import clay "../vendor/clay/bindings/odin/clay-odin"

@(private)
settings_speech :: proc(ui: ^Ui_State) {
	switch ui.settings_tab {
	case 0:
		if clay.UI(clay.ID("DictationGroup"))(settings_box()) {
			if clay.UI(clay.ID("RowStt"))(settings_row()) {
				settings_check(
					"TgStt",
					ui.prefs.stt_enabled,
					"Speech to text",
					"Dictate drafts and transcribe audio messages on your device.",
				)
			}
		}
		if ui.prefs.stt_enabled {
			if clay.UI(clay.ID("TranscriptionGroup"))(settings_box()) {
				settings_group(N_("Transcription model"))
				clay.Text(
					tr("Select a model to download it for dictation and audio messages."),
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
				)
				for model, i in STT_MODELS {
					selected := stt_model(ui.prefs.stt_model) == i
					if clay.UI(clay.ID("SttModel", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							layoutDirection = .TopToBottom,
							padding = clay.PaddingAll(10),
							childGap = 6,
						},
						backgroundColor = selected ? SELECTED : (hovered() ? HOVER : CARD),
						border = {
							color = selected ? ACCENT : FIELD_BORDER,
							width = {1, 1, 1, 1, 0},
						},
						cornerRadius = rr(8),
					},
					) {
						_ = hovered()
						active := selected && ui.stt.file != nil && ui.stt.purpose == .Download
						label := ui.stt.ready[i] ? tr("Downloaded") : tr("Not downloaded")
						fraction: f32
						if active {
							bytes := f32(model.sizes[ui.stt.model]) * f32(ui.stt.percent) / 100
							for j in 0 ..< int(ui.stt.model) {bytes += f32(model.sizes[j])}
							fraction = bytes / f32(model.bytes)
							label =
								ui.stt.status == 'D' ? fmt.tprintf(tr("Downloading: %d%%"), int(fraction * 100)) : tr("Verifying download...")
						}
						if clay.UI(clay.ID_LOCAL("SttModelHeading"))(
						{
							layout = {
								sizing = {width = clay.SizingGrow()},
								childGap = 8,
								childAlignment = {y = .Center},
							},
						},
						) {
							settings_radio_mark(selected)
							row_labels(
								model.label,
								fmt.tprintf("%s · %s", human_size(model.bytes), label),
							)
						}
						clay.Text(
							tr(model.languages),
							{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
						)
						if active {
							if clay.UI(clay.ID_LOCAL("SttDownloadTrack"))(
							{
								layout = {
									sizing = {
										width = clay.SizingGrow(),
										height = clay.SizingFixed(4),
									},
								},
								backgroundColor = PLATE,
								cornerRadius = rr(2),
							},
							) {
								if fraction > 0 {
									if clay.UI(clay.ID_LOCAL("SttDownloadFill"))(
									{
										layout = {
											sizing = {
												width = clay.SizingPercent(fraction),
												height = clay.SizingGrow(),
											},
										},
										backgroundColor = ACCENT,
										cornerRadius = rr(2),
									},
									) {}
								}
							}
							settings_button("SttCancel", "Cancel")
						}
					}
				}
			}
		}
	case 1:
		if clay.UI(clay.ID("ReadAloudGroup"))(settings_box()) {
			if clay.UI(clay.ID("RowTts"))(settings_row()) {
				settings_check(
					"TgTts",
					ui.prefs.tts_enabled,
					"Read aloud",
					"Read messages on your device in 31 languages. Downloads about 145 MB on first use.",
				)
			}
		}
		if ui.prefs.tts_enabled {
			if clay.UI(clay.ID("TtsModel"))(settings_box()) {
				row_labels(
					"Speech model",
					"Shared by all ten voices and 31 languages. Downloads once.",
				)
				settings_tts_download(ui, 0)
			}
			if clay.UI(clay.ID("TtsVoices"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					childGap = 6,
				},
			},
			) {
				for voice, i in TTS_VOICES {
					if i == 0 || TTS_DESCRIPTIONS[i] != TTS_DESCRIPTIONS[i - 1] {
						clay.Text(
							tr(TTS_DESCRIPTIONS[i]),
							{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
						)
					}
					selected := clamp(ui.prefs.tts_voice, 0, len(TTS_VOICES) - 1) == i
					if clay.UI(clay.ID("TtsVoice", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							padding = {left = 10, right = 8, top = 6, bottom = 6},
							childGap = 10,
							childAlignment = {y = .Center},
						},
						backgroundColor = selected ? SELECTED : (hovered() ? HOVER : CARD),
						border = {
							color = selected ? ACCENT : FIELD_BORDER,
							width = {1, 1, 1, 1, 0},
						},
						cornerRadius = rr(8),
					},
					) {
						_ = hovered()
						settings_radio_mark(selected)
						if clay.UI(clay.ID_LOCAL("VoiceTitle"))(
						{layout = {sizing = {width = clay.SizingGrow()}}},
						) {
							clay.Text(
								voice,
								{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT},
							)
						}
						settings_button(fmt.tprintf("TtsPreview%d", i), "Preview")
					}
				}
			}
		}
	}
}
