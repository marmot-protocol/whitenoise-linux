package main

// Native language names and spoken previews intentionally keep their language.
@(private)
TTS_LANGUAGES := [?]struct {
	code, label, preview: string,
} {
	{"en", "English", "Hello. This is how your messages will sound."},
	{"ja", "日本語", "こんにちは。メッセージをこの声で読み上げます。"},
	{"it", "Italiano", "Ciao. Questa è la voce che leggerà i tuoi messaggi."},
	{"de", "Deutsch", "Hallo. So werden deine Nachrichten klingen."},
	{"fr", "Français", "Bonjour. Voici la voix qui lira vos messages."},
	{"es", "Español", "Hola. Así sonarán tus mensajes."},
	{"pt", "Português", "Olá. Esta é a voz que vai ler suas mensagens."},
	{"ko", "한국어", "안녕하세요. 이 목소리로 메시지를 읽어 드립니다."},
	{
		"ar",
		"العربية",
		"مرحباً. هذا هو الصوت الذي سيقرأ رسائلك.",
	},
	{
		"bg",
		"Български",
		"Здравей. Така ще звучат твоите съобщения.",
	},
	{"cs", "Čeština", "Ahoj. Takto budou znít tvoje zprávy."},
	{"da", "Dansk", "Hej. Sådan vil dine beskeder lyde."},
	{
		"el",
		"Ελληνικά",
		"Γεια σου. Έτσι θα ακούγονται τα μηνύματά σου.",
	},
	{"et", "Eesti", "Tere. Nii kõlavad sinu sõnumid."},
	{"fi", "Suomi", "Hei. Tältä viestisi kuulostavat."},
	{
		"hi",
		"हिन्दी",
		"नमस्ते। आपके संदेश इस आवाज़ में सुनाई देंगे।",
	},
	{"hr", "Hrvatski", "Bok. Ovako će zvučati tvoje poruke."},
	{"hu", "Magyar", "Szia. Így fognak hangzani az üzeneteid."},
	{"id", "Bahasa Indonesia", "Halo. Seperti inilah suara pesanmu."},
	{"lt", "Lietuvių", "Sveiki. Taip skambės jūsų žinutės."},
	{"lv", "Latviešu", "Sveiki. Tā skanēs tavas ziņas."},
	{"nl", "Nederlands", "Hallo. Zo zullen je berichten klinken."},
	{"pl", "Polski", "Cześć. Tak będą brzmiały twoje wiadomości."},
	{"ro", "Română", "Bună. Așa vor suna mesajele tale."},
	{
		"ru",
		"Русский",
		"Привет. Так будут звучать твои сообщения.",
	},
	{"sk", "Slovenčina", "Ahoj. Takto budú znieť tvoje správy."},
	{"sl", "Slovenščina", "Živijo. Tako bodo zvenela tvoja sporočila."},
	{"sv", "Svenska", "Hej. Så här kommer dina meddelanden att låta."},
	{"tr", "Türkçe", "Merhaba. Mesajların bu sesle okunacak."},
	{
		"uk",
		"Українська",
		"Привіт. Так звучатимуть твої повідомлення.",
	},
	{"vi", "Tiếng Việt", "Xin chào. Đây là giọng đọc tin nhắn của bạn."},
}

@(private)
tts_language :: proc(ui: ^Ui_State, text: string) -> int {
	code := ui.prefs.locale
	// Kana identify Japanese, including mixed Japanese and Latin text.
	// ponytail: other text uses the UI locale; add language identification
	// if automatic Latin-language switching is needed.
	for r in text {
		if (r >= '\u3040' && r <= '\u30ff') || (r >= '\uff66' && r <= '\uff9f') {
			code = "ja"
			break
		}
	}
	for language, i in TTS_LANGUAGES {
		if language.code == code ||
		   (len(code) > 2 && code[:2] == language.code && (code[2] == '-' || code[2] == '_')) {
			return i
		}
	}
	return 0
}
