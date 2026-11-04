package main

import "core:fmt"
import rl "sdlrl"

import "nendo"

@(private)
settings_speech :: proc(ui: ^Ui_State) {
	// A completed download or read removes a row/bar. Do not let a finger
	// aimed at that vanished action select the card that moved underneath.
	stt_busy, tts_busy := ui.stt.file != nil, ui.tts.file != nil
	if (speech_was_stt && !stt_busy) || (speech_was_tts && !tts_busy) {
		speech_shift_until = rl.GetTime() + 0.5
	}
	speech_was_stt, speech_was_tts = stt_busy, tts_busy
	switch ui.settings_tab {
	case 0:
		if nendo.box(nendo.id("DictationGroup"))(settings_box()) {
			settings_group(tr("On this device"))
			if nendo.box(nendo.id("RowStt"))(settings_row()) {
				settings_check(
					"TgStt",
					ui.prefs.stt_enabled,
					tr("Speech to text"),
					tr("Dictate drafts and transcribe audio messages on your device."),
				)
			}
		}
		if ui.prefs.stt_enabled {
			if nendo.box(nendo.id("TranscriptionGroup"))(settings_box()) {
				settings_group(tr("Transcription model"))
				nendo.text(
					tr("Select a model to download it for dictation and audio messages."),
					{font = FONT_BODY, size = 11, color = TEXT_DIM},
				)
				for model, i in STT_MODELS {
					selected := ui.prefs.stt_model != "" && stt_model(ui.prefs.stt_model) == i
					if nendo.box(nendo.id("SttModel", u32(i)))(
					{
						width = nendo.grow(),
						direction = .Column,
						padding = nendo.pad(10),
						gap = 6,
						color = selected ? SELECTED : (hovered() ? HOVER : CARD),
						border = {
							color = selected ? ACCENT : FIELD_BORDER,
							width = {1, 1, 1, 1, 0},
						},
						radius = rr(8),
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
								ui.stt.status == 'D' ? fmt.tprintf(tr("Downloading: %d%%"), int(fraction * 100)) : tr("Preparing download...")
						}
						if nendo.box(nendo.id_local("SttModelHeading"))(
						{width = nendo.grow(), gap = 8, align = {y = .Center}},
						) {
							settings_radio_mark(selected)
							row_labels(
								model.label,
								fmt.tprintf("%s · %s", human_size(model.bytes), label),
							)
						}
						nendo.text(
							ui.keys_confirm == model.name ? tr("Tap again to download this model.") : tr(model.languages),
							{font = FONT_BODY, size = 11, color = TEXT_DIM},
						)
						if active {
							if nendo.box(nendo.id_local("SttDownloadTrack"))(
							{
								width = nendo.grow(),
								height = nendo.fixed(4),
								color = FIELD_BORDER,
								radius = rr(2),
							},
							) {
								if fraction > 0 {
									if nendo.box(nendo.id_local("SttDownloadFill"))(
									{
										width = nendo.percent(fraction),
										height = nendo.grow(),
										color = ACCENT,
										radius = rr(2),
									},
									) {}
								}
							}
							settings_button("SttCancel", tr("Cancel"))
						}
					}
				}
			}
		}
	case 1:
		if nendo.box(nendo.id("ReadAloudGroup"))(settings_box()) {
			settings_group(tr("On this device"))
			if nendo.box(nendo.id("RowTts"))(settings_row()) {
				settings_check(
					"TgTts",
					ui.prefs.tts_enabled,
					tr("Read aloud"),
					tr(
						"Read messages on your device in 31 languages. Downloads about 145 MB on first use.",
					),
				)
			}
		}
		if ui.prefs.tts_enabled {
			if nendo.box(nendo.id("TtsModel"))(settings_box()) {
				row_labels(
					tr("Speech model"),
					tr("Shared by all ten voices and 31 languages. Downloads once."),
				)
				settings_tts_download(ui, 0)
			}
			if nendo.box(nendo.id("TtsVoices"))(
			{width = nendo.grow(), direction = .Column, gap = 6},
			) {
				for voice, i in TTS_VOICES {
					selected := clamp(ui.prefs.tts_voice, 0, len(TTS_VOICES) - 1) == i
					if nendo.box(nendo.id("TtsVoice", u32(i)))(
					{
						width = nendo.grow(),
						direction = .Row,
						padding = {left = 10, right = 8, top = 6, bottom = 6},
						gap = 10,
						align = {y = .Center},
						color = selected ? SELECTED : (hovered() ? HOVER : CARD),
						border = {
							color = selected ? ACCENT : FIELD_BORDER,
							width = {1, 1, 1, 1, 0},
						},
						radius = rr(8),
					},
					) {
						_ = hovered()
						settings_radio_mark(selected)
						if nendo.box(nendo.id_local("VoiceTitle"))(
						{width = nendo.grow(), direction = .Column, gap = 3},
						) {
							nendo.text(voice, {font = FONT_TITLE, size = 13, color = TEXT})
							nendo.text(
								tr(TTS_DESCRIPTIONS[i]),
								{font = FONT_BODY, size = 11, color = TEXT_DIM},
							)
						}
						settings_button(fmt.tprintf("TtsPreview%d", i), tr("Preview"))
					}
				}
			}
		}
	}
}

@(private)
speech_was_stt, speech_was_tts: bool
@(private)
speech_shift_until: f64
