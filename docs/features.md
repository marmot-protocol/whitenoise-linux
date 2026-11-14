<sub>REFERENCE&ensp;·&ensp;FEATURE TOUR</sub>

# Feature tour

### An encrypted group messenger, area by area, including the part where it plays NES cartridges.

Everything White Noise Linux does, grouped by area. The [README](../README.md) has the short version; this page keeps the exact keys, limits and link formats.

<picture>
  <source media="(max-width: 600px) and (prefers-color-scheme: dark)" srcset="../assets/docs/features-tour-narrow-dark.svg">
  <source media="(max-width: 600px)" srcset="../assets/docs/features-tour-narrow-light.svg">
  <source media="(prefers-color-scheme: dark)" srcset="../assets/docs/features-tour-dark.svg">
  <img alt="The app's seven areas. Messaging: MLS group chats with NIP-59 invites, replies, edits, polls and math, folders that file chats, Ctrl+K search over local history, an offline send queue and on-device translation, plus Nostr cards and emoji from NIP-30, NIP-34, NIP-51 and NIP-84. Media: albums, video, voice, PDFs, archives, 3D models, and map and call cards, sent over MIP-04. Games: a .nes file gets a Play button, for mappers 0, 1, 2, 3, 4 and 7, with no saves or gamepad. Accounts: several at once, with local nsec keys, NIP-46 remote signers through bunker links, and contacts as CSV or JSON. Look and feel: 35 themes and 5 accents from themes/*.toml, 5 languages at runtime, hover previews and full keyboard navigation. Mobile Linux: one view at a time with bottom navigation and Back, which keeps your draft, long-press actions and Linux ARM64 packages. Privacy and data: one vault and one password for every secret, Lock now without closing the window, OTLP metrics and audit logging off until you opt in, and backups that skip account keys." src="../assets/docs/features-tour-light.svg" width="880">
</picture>

## Messaging

One-to-one and group chats are end-to-end encrypted through Marmot's MLS, with sealed-sender invites over NIP-59. This is the largest area, so it is split by what you are doing.

### Chats, groups and who may change them

- **New chat opens a searchable contact picker.** Choose a contact, or select New group to set its name and photo.
- **A group needs a first member.** Type to filter your contacts and select one, or paste a Nostr address.
- **Group settings belong to admins.** Only admins see the name, description, photo, disappearing-message, and issue-tracking controls.
- **Only admins promote, demote, or remove members.** Nicknames change your local labels and remain available to other members.
- **Unread state is tracked per chat.** It shows up as badges on the rail.

<details>
<summary><b>What members see, and what developer mode adds</b></summary>

- The rename field starts with the current group name.
- Members who are not admins can view the group's name, description, photo, and current disappearing-message timer. The timer reads in full units, such as "90 days".
- Developer mode shows a clickable MLS badge in chat headers when space allows. Open it to inspect and copy the group ID, or to read the current encryption revision (MLS epoch).

</details>

### Writing, sending and forwarding

- **Messages are Markdown.** Bodies support typeset `$` math blocks, reactions, replies, edits with history, forwarding, and search.
- **Enter sends; Shift+Enter starts a new line.** You can also click Send, which reads Save while you edit a message.
- **Messages written offline are not lost.** A durable on-disk send queue sends them when you reconnect.
- **Polls explain what is missing.** Creation keeps your draft open and names a missing question or fewer than two nonblank options.
- **Forwards show their progress until they finish.** A status strip names the destination through preparation and sending, even if you switch chats.

<details>
<summary><b>Composer, poll and forward details</b></summary>

- Hover over the attach, emoji, and microphone buttons for their labels.
- In poll creation, Multiple choice is an on/off switch. Create is the primary action and Cancel is secondary.
- The Forward picker shows the message's first line, or its first attachment's filename, above the destination filter.
- Forwarded attachments download and prepare in the background.
- Failed forwards can be retried from the destination chat.
- A confirmation names the destination after every part succeeds. A partial or cancelled forward does not report full success.

</details>

### How messages and links render

- **Single newlines survive.** Markdown bodies keep them.
- **Links keep their labels and destinations.** HTTP(S) links show their URL on hover, and opening one goes through the external-link guard.
- **Long messages fold after 6 lines.** Settings > Appearance sets the message line limit for messages and event cards; 0 shows them in full without Read more.
- **Chat-list previews show reading text.** Markdown markup is left out.

<details>
<summary><b>The external-link guard, for addresses longer than the dialog</b></summary>

Long addresses in the guard scroll horizontally without breaking path words. Scroll over the address to read it in full.

</details>

### Cards for Nostr events and njump links

Linked Nostr events render as cards instead of raw identifiers. Cards with an Open in client button use your configured Nostr web client.

| You paste or link | What you get |
| --- | --- |
| `https://njump.me/<reference>` or `http://njump.me/<reference>` | The same as a `nostr:` reference: profile chips for `npub`/`nprofile`, event cards for `note`/`nevent`/`naddr` |
| Highlight (kind 9802, NIP-84) | The selected passage in large type, quieter context, avatar bylines, compact source tiles |
| Pull request (kind 1618) or Git issue (kind 1621, NIP-34) | Its own icon and label, a bold subject when present, author and timestamp lines, a Markdown description |
| Git patch (kind 1617, NIP-34) | Mail subject, author, repository, revision or series marker, file/addition/deletion counts, and the diff |

<details>
<summary><b>Highlight, issue and patch cards in detail</b></summary>

Highlights:

- Cards start with the highlighter's byline, without a kind label.
- Source tiles identify the domain, event, or structured source.
- Source links and the full-width Open in client button use the external-link guard.
- Read more expands the quotation, context, and commentary together.
- Media-only highlights retain their source tiles.

Pull requests and Git issues:

- The author and the timestamp sit on separate lines.
- Long subjects wrap to three lines with an ellipsis.
- A full-width Open in client button uses your configured Nostr web client.

Git patches:

- The diff preserves code as literal monospace text, with tinted additions and deletions.
- Read more expands the description and diff.
- Inline diffs stop at 1,000 wrapped rows; the complete patch is available through Open in client.
- Cover letters show their subject and description without invented change counts.

</details>

### Timestamps that read in your timezone

- **Markdown timestamps localize themselves.** A token such as `<t:1791280800:F>` displays in your current timezone with a clock icon.
- **Hovering shows the source.** You see the absolute local date and time and the original token.
- **Day dividers say Today.** They follow the current local day and update at midnight.
- **The chat list counts back from today.** It shows the time for today, Yesterday, then the date.

<details>
<summary><b>Timestamp styles, and what follows your date settings</b></summary>

- Styles `t`, `T`, `d`, `D`, `f`, `F`, `s`, `S`, and `R` cover time, date, combined, and live relative labels. Omitting the style selects `f`.
- Absolute labels follow your Date format and Time format settings and the app language, like the rest of the app's dates.
- Invalid tokens stay literal, and unsupported dates remain readable tokens.
- Changing the Date format, Time format or language updates every visible date at once, including the open chat.

</details>

### Search and export

- **Ctrl+K searches literal text in locally stored history.** Archived chats are included; unsynced messages are not searched.
- **Filters narrow it down.** Filter by chat, sender, local date range, or attachment type, and use More results to page through matches.
- **Export writes the loaded chat window.** Choose HTML or Markdown from the members panel.

<details>
<summary><b>Date ranges, result handling and HTML export</b></summary>

Search:

- Search all chats takes start and end days in your local calendar, written the way the app shows dates (`Jun 12`, `12 Jun 2026` or `2026-06-12`). Without a year, the current one is used.
- Results are dated the way the chat's day dividers are.
- Opening a result returns to Chats and loads older history when needed.
- Closing search preserves its query and results; switching accounts clears them.

Export:

- HTML prepares embedded images in the background and shows image progress before opening the save dialog.
- Unavailable images appear as notes in the transcript.
- Leaving the chat or changing accounts discards an unfinished export.

</details>

### Emoji, standard and custom

- **Emoji search accepts names and shortcodes.** `100` finds hundred points and `thumbsup` finds thumbs up, with or without surrounding colons.
- **Recent emoji survive restarts.** The picker keeps your eight most recent choices, newest first.
- **Custom emoji sets come from Nostr.** Settings > General > Messaging > Custom emoji browses recent [NIP-51 kind-30030 emoji sets](https://github.com/nostr-protocol/nips/blob/master/51.md) from your event-fetch relays.
- **Custom `:shortcode:` emoji use NIP-30.** The image goes out as an encrypted attachment, not a public link.

<details>
<summary><b>Browsing and importing emoji sets</b></summary>

- Sets from your contacts come first, with A-Z ordering within each group and a saved Contacts only filter.
- Sets with no valid emoji stay hidden.
- Each row shows artwork and an author mention chip.
- Search by title, author, or shortcode, then open a set to preview it. Previews appear as each download finishes.
- Import the whole set, or use the + button beside one emoji.
- Imported emoji keep their set title and verified author after a restart.
- Imports preserve existing shortcodes and report skipped entries and failed downloads.
- Browsing previews and importing contact HTTPS image hosts. PNG, JPEG, GIF, and WebP are supported when the image decoder accepts them.

</details>

<details>
<summary><b>How a custom emoji travels inside an encrypted group</b></summary>

- The message carries an `["emoji", shortcode, url]` tag pointing at that attachment's Blossom URL.
- Reactions work the same way: a `:shortcode:` reaction carries its own `imeta` and emoji tag.
- Forwards keep the tags.
- MDK's `marmot_send_tagged_media` and `marmot_react_with_media` send them. MDK keeps the media key for reaction images the way it does for chat media.

</details>

### Translation on your device

Native Linux builds translate messages and audio transcriptions locally with [TranslateGemma 4B Q4_K_M](https://huggingface.co/mradermacher/translategemma-4b-it-GGUF). The first translation downloads about 2.5 GB of model files; later translations work offline.

1. Enable it in Settings > General > Language > Message translation.
2. Choose the target language.
3. Use Translate in a message's context menu. For audio, finish a transcription and use Translate below its expanded text.

Enabling it accepts the [Gemma terms](https://ai.google.dev/gemma/terms) and [prohibited use policy](https://ai.google.dev/gemma/prohibited_use_policy).

<details>
<summary><b>Automatic translation, source detection and limits</b></summary>

- Show original and Show translation switch the displayed text without changing the stored message or original transcription.
- Automatic translation processes received messages and expanded, completed audio transcriptions as you read them. It does not start transcription.
- Source detection runs locally with fastText. If it cannot identify the language, choose the source in settings.
- Results stay in session memory and are discarded when you change chats, accounts, or language settings.
- Messages beyond the model's input or output token limits fail rather than return a truncated translation.

</details>

### Folders that file chats themselves

Folder rules file chats automatically. A chat goes to the first folder, in folder order, whose rules match; a chat you move by hand stays put.

<picture>
  <source media="(max-width: 600px) and (prefers-color-scheme: dark)" srcset="../assets/docs/features-rules-narrow-dark.svg">
  <source media="(max-width: 600px)" srcset="../assets/docs/features-rules-narrow-light.svg">
  <source media="(prefers-color-scheme: dark)" srcset="../assets/docs/features-rules-dark.svg">
  <img alt="How folder rules file one chat. The chat, Marmot meetup, has 6 people including you, unread messages and no draft. A chat moved by hand stays in that folder and skips the rules; Follow folder rules in the move dialog hands it back. Otherwise the folders are checked in order. Folder 1, Work, matches all of its rules: name includes standup fails and fewer than 10 people holds, so Work does not match. Folder 2, Busy, matches any one rule: more than 5 people holds and has a draft fails, so the chat files under Busy. Folder 3, Friends, comes later in order and is not checked. Unfiled takes a chat when no folder matches." src="../assets/docs/features-rules-light.svg" width="880">
</picture>

Each folder matches all of its rules or any one of them.

| Rule | Matches a chat that |
| --- | --- |
| Name includes | Has a word in its name |
| Has member | Has a member with this npub |
| Fewer than, More than | Has fewer or more than N people, you included |
| Has unread messages | Has unread messages |
| Has a draft | Has unsent composer text saved |
| Is Whip | Is a [Whip](whip.md) project |

- **Hand placement wins over rules.** Choosing "Follow folder rules" in the move dialog hands the chat back to the rules.
- **Deleting a folder asks first.** This applies from both Settings and its context menu; only the folder is removed and its chats stay in your chat list.
- **Settings > Folders lists every chat under the folder it files into.** Drag a chat onto a folder (Unfiled included) to keep it there, or drag a folder header to reorder folders.

<details>
<summary><b>Checked boxes, sidebar modes and when member lists are read</b></summary>

- In Settings > Folders, chats placed by hand show a checked box. Clearing it hands the chat back to the rules.
- In Recent mode, every folder appears beside Chats, Unread, Groups, and Whip as a filter, keeping recent activity order within the selected folder.
- In Grouped mode, empty folders stay out of the chat list sidebar.
- Member rules read each group's member list on every chat-list refresh, and only while such a rule exists.

</details>

## Media

Attachments travel over Marmot's encrypted MIP-04 path. Profile pictures are the one deliberate exception: they go out publicly via Blossom.

### Attachments and previews

- **Drag files into the open chat to stage them.** Files prepare in the background, with image thumbnails when available.
- **Most files open in place.** Image albums, inline video (libmpv), voice messages, and a preview modal cover the common formats.
- **Stickers have their own guide.** [Personal stickers and Sonar sticker packs](stickers.md) come from MDK and sync across your devices, with pack previews from received stickers.
- **Audio can be transcribed locally.** Enable Speech to text in Settings, then use the Transcribe button on an audio card.

| The preview modal reads | Through |
| --- | --- |
| PDFs | poppler |
| Archives | libarchive |
| STL, OBJ, FBX, GLB and G-code models | A 3D view you can orbit |
| Source files | Syntax highlighting |

<details>
<summary><b>Staging, PDF fullscreen, M4A files and GLB limits</b></summary>

Staging:

- Remove unwanted files with the × on each chip. Press Enter when preparation finishes to send.
- Drops outside the conversation or over a modal do not attach files.

PDFs:

- PDFs have fullscreen controls on attachment tiles and in previews.
- The fullscreen modal fills the app window without changing desktop fullscreen.
- Pages fit the window and render at its pixel density, with previous/next controls.
- Exit fullscreen returns to the preview; Escape closes it.

M4A files use the audio card and its Transcribe button, including attachments labeled `video/mp4` by another client.

GLB attachments open as static 3D scenes with orbit, zoom, and the model inspector:

- The viewer reads node transforms, material factors, and embedded PNG/JPEG textures on UV0.
- GLB animation, skinning, morph targets, vertex colors, and Draco/meshopt compression are not supported.
- External resources are never fetched; translucent materials use alpha cutouts.

</details>

### Image links, maps and call cards

- **Direct image links show inline.** JPG, PNG, GIF, and WebP links show the image above its clickable URL.
- **Map links become an OpenStreetMap card.** Android location shares and pasted map links get a card you can pan and zoom.
- **Call links become a call card.** Signal call links and Jitsi Meet room links show a join button and a line saying the call runs outside White Noise.
- **Link previews are on by default.** Turn them off in Settings > Advanced > Security & privacy to stop new automatic preview requests, including supported-site cards; attachment downloads are unaffected.

Loading a card contacts a third party. This is who learns what:

| Who is contacted | What they learn |
| --- | --- |
| The link preview host | Your IP address |
| tile.openstreetmap.org | Which map tiles you load |
| Nominatim, for place names | Coordinates, rounded to three decimals |
| Your Open in map site | The location |
| A Jitsi host other than meet.jit.si | One request for `external_api.js` |

The app never contacts Google on its own.

<details>
<summary><b>Image grids and lightbox</b></summary>

- Messages ending with two or more standalone image links show them as one grid.
- Four portrait images use two rows of two, for both links and attachments.
- Click a grid image to browse the loaded images in the lightbox.

</details>

<details>
<summary><b>Which map links get a card, and where tiles are kept</b></summary>

- Locations shared from the Android app (`Location: https://maps.google.com/maps?q=<lat>,<lon>`) show an OpenStreetMap card in place of the Google link.
- Pasted OpenStreetMap, Kagi Maps, Apple Maps, and Google Maps links that name a point or a map view get the same card, opened at the link's zoom: markers, place pages, search pages, and plain map views. Examples: `https://www.openstreetmap.org/?mlat=0&mlon=0#map=12/0/0`, `https://kagi.com/maps/#14.58/0/0`, or a Google `/maps/place/…/@lat,lon,17z` link.
- Google's country domains such as google.it are not recognized.
- Drag the map to pan, scroll or use the zoom buttons to zoom, and Recenter to return to the pin.
- The card names the town and country and offers Copy coordinates and an Open in link.
- Settings > Advanced > Open locations in picks the site that link opens: OpenStreetMap (the default), Apple Maps, Kagi Maps, or Google Maps. The map on the card always comes from OpenStreetMap.
- The first card asks before loading anything. Settings > Advanced > Location maps changes the answer later, and turning off link previews hides the cards.
- Tiles are cached in the encrypted media cache under keyed file names, up to 1 GB with the oldest fetches removed first, and are fetched again after a week.

</details>

<details>
<summary><b>How a Jitsi server proves it is one</b></summary>

- Signal call links look like `https://signal.link/call/#key=…`. Each call card is styled after its app.
- meet.jit.si rooms are recognized from the URL.
- For any other host, a one-segment room link (`https://meet.example.org/Standup`) prompts one request to `https://<host>/external_api.js`, the script every Jitsi Meet server publishes. Hosts that serve it get the card, and the answer is kept until the app restarts.
- Clicking goes through the external-link guard like any other link.
- If Signal Desktop or the Jitsi Meet desktop app is registered for `sgnl://` or `jitsi-meet://`, the call opens there directly; otherwise it opens in your browser.
- Turning off link previews shows plain URLs and stops the Jitsi host requests.

</details>

### Sending a location

1. Use the pin button beside the composer.
2. Drag or zoom the map to choose a point, or choose Use current location to request permission through the Linux desktop's location portal.
3. Review the pin, then choose Send location.

Current location needs a desktop portal backend and location service; if it is unavailable or denied, pick a point manually. Sending keeps your composer draft and staged attachments and uses Android's location message format.

## Games

A `.nes` attachment, or an archive holding nothing but one `.nes` file, shows a cartridge tile with a Play button. The game runs in a modal.

| Key | NES button |
| --- | --- |
| Arrow keys | Move |
| X | A |
| Z | B |
| Enter | Start |
| Shift | Select |
| Escape | Closes the game |

Supported boards are mappers 0, 1, 2, 3, 4 and 7 (NROM, MMC1, UxROM, CNROM, MMC3, AxROM). There are no battery saves, save states or gamepad input.

## Identity & accounts

Accounts hold Nostr keys, either local or in a remote signer, and several can run at once.

- **Local nsec keys and NIP-46 remote signers sit side by side.** Connected accounts receive messages in the background.
- **The app opens on the account you used last.** For a remote-signer account it starts on a local one and switches once the signer connects.
- **Remote signers pair by link.** Connect with a `bunker://` link, or scan or copy a `nostrconnect://` pairing link.
- **People lists the people you follow.** Starting a chat does not add someone to People.
- **Your profile is public.** The optional Verified address field holds a Nostr identifier (NIP-05), not your email address.

<details>
<summary><b>Signers, removal, profiles and contacts in detail</b></summary>

Remote signers:

- Approve requests in your signer. Pending operations show their status and approval links.

Removing an account:

- The trash button on an account row (the Accounts switcher or the Profile page) removes that account from this device after you confirm.
- Its keys and local chats are deleted. Its groups are not notified, so other members still see it.

People and profiles:

- Private local-only nicknames, an archive, and npub QR codes are also available.
- Profile popups have a Message button. It opens your existing DM, including an archived DM without restoring it, or creates a new DM if none is reusable.
- Empty display name, about, and Lightning inputs show a muted "Not set" hint. Empty profile summary values also say "Not set".
- Profiles without a loaded name show a deterministic adjective and animal, such as "Magnetic Panda", derived from their public key. Published names replace it when loaded; local nicknames take precedence. The npub remains visible on profile cards.

Contacts:

- Import and export contacts as CSV or JSON from the contacts rail.
- Imports skip existing contacts and duplicate npubs, restore private nicknames and blocked state, and report added, skipped, and failed records.
- Published profile names still come from Nostr.

</details>

### Setup prompts for AI agents

Settings > AI agents offers setup prompts for Hermes, OpenClaw, OpenCode, Codex, and Claude Code. White Noise does not install anything or share your private key.

1. Review and copy a prompt containing your active account's full public npub. Copy prompt is the main action.
2. Paste it into an agent you run and trust.

Each setup card also has a secondary Copy public key button and links to connector documentation. Escape from a setup card returns to the connector list.

## Look & feel

Thirty-five bundled themes and five accent colors, all data-driven from `themes/*.toml`. Drop your own pack in the data dir.

- **Hovering a theme tile previews it.** Leaving the tile or pressing Escape restores your theme; clicking saves the choice.
- **Five languages switch at runtime.** English, Italian, German, Japanese, and Korean cover search dialogs, theme notifications, and confirmation errors too.
- **The keyboard reaches everything.** Native desktop notifications, a command palette, and full keyboard navigation are built in.
- **The conversation can sit in a column.** Settings > Appearance > Center the conversation keeps the timeline and composer at most 720px wide.
- **Reduce motion hides animated backdrops.** Synth, dust, scan, and wave backdrops go, including the vault gate's synth backdrop; static decorations remain visible.

Some themes change more than colors:

| Theme | What it changes |
| --- | --- |
| AMOLED | Black and white, 25% color saturation |
| Film Noir | Moving film grain over the whole view |
| Royale, Royale Dark | XP Royale's blue chrome |
| Chalkboard, Crayon | Kalam lettering at 125%, sketched avatars |
| Terminal | A fixed green accent |
| Sidecar collection | All 21 themes from [dmnyc's Sidecar](https://github.com/dmnyc/sidecar) |

<details>
<summary><b>Theme packs, accents and button text</b></summary>

- Each pack defines its accent labels with `accent-name-1` through `accent-name-5`, matching the order of `accent-base`.
- The theme editor labels accent names separately from accent colors and preserves both.
- Button text derives separately for each accent color using sRGB contrast. Custom packs can set `on-accent` to override the text color for all five accents.

</details>

<details>
<summary><b>The Appearance page, gallery and theme quirks</b></summary>

Appearance layout:

- Wide windows put controls, the theme gallery, and a live conversation preview side by side.
- Medium windows put controls beside stacked themes and preview; all three panels scroll independently.
- Narrow windows stack them on one page.
- The preview uses the normal chat renderer with a fictional marmot conversation, not your messages or draft. It is static: its header and messages do not react to the pointer, and it has no composer.

Centered conversation:

- Settings search accepts both "center" and "centre".
- Narrower windows use the available width; turning it off restores full width.

Theme gallery:

- The gallery has separate Dark and Light views and collection headings. Collection headings have no links.
- Settings search finds the picker by any loaded theme's displayed name, including custom packs, without changing your theme.
- Selecting a Sidecar theme shows its source credit on the page and the selected tile.

Theme quirks:

- AMOLED uses black and white theme colors and hides its accent chooser. Its whole-view pass reduces color saturation to 25%, including avatars, emoji, and media.
- Film Noir's grain is visible and moving, and covers photos and video. Reduce motion freezes the grain; the filter adds no contrast or vignette.
- Royale and Royale Dark pair the blue chrome with pearl or charcoal surfaces and bevelled controls.
- Terminal hides its accent chooser.
- Chalkboard and Crayon use bundled Kalam lettering, textured surfaces, and fixed rough strokes.
- The Hand-drawn filter toggle in Appearance turns the material effect off without changing the palette or lettering size. This filter preference is shared by both themes.
- Chalkboard erases the photo to reveal its identity fingerprint on avatar hover, then redraws the photo when the pointer leaves. Other themes keep the swivel reveal.

Chat transitions follow the conversation, not its position in the list. New messages can reorder the list without sliding the open chat.

</details>

## Mobile Linux

Narrow windows show one view at a time, with full-width chat and contact lists. Linux ARM64 packages use the same interface (see [Install](install.md)).

- **Bottom navigation switches pages.** Back returns from a conversation and keeps your draft and staged attachments.
- **Touch replaces the pointer.** Tap or long-press a message for its actions, and long-press a chat for its row menu.
- **The conversation header holds the rest.** Back, search, and a menu with files, mentions, settings and members.
- **Typing waits for you.** Tap the composer to activate platform text input; opening a conversation does not raise the on-screen keyboard.

<details>
<summary><b>Rotation, scrolling, short screens and the keyboard</b></summary>

- Settings, forms, dialogs and media controls reflow or scroll to fit the window.
- The Chats menu holds Lock now and the command palette.
- The status bar appears only while you are offline or connecting.
- Rotating a phone keeps the text size; landscape gains room and the navigation drops its labels.
- Drag overflowing toolbars and choice rows sideways and page content vertically.
- Reduce motion keeps direct finger scrolling but disables the fling.
- On short screens, navigation gives the active view more room; Back restores it.
- Short conversations also hide the status readout, but retain progress and error banners.
- The compositor supplies the on-screen keyboard through SDL's platform text-input support.

</details>

## Privacy & data

- **One password-encrypted vault holds every secret.** The [security model](security.md) explains it.
- **Lock now closes the runtime without closing the window.** It clears the vault key and session state and returns to the password gate; unlock with your vault password to reconnect.
- **Backups cover settings, drafts, custom emoji, and themes.** They are encrypted; account keys and message history are not included.
- **Metrics and audit logs are opt-in.** OTLP metrics and audit logging stay off until you turn them on in Settings.

Lock now lives in the status bar (the Chats menu on phones) and in the command palette.

## Third-party marks

The AI agent icons identify third-party products, not endorsements. Hermes artwork comes from [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent), OpenClaw's mark from [openclaw.ai](https://openclaw.ai), and OpenCode's mark from its [brand assets](https://opencode.ai/brand); their MIT license notices are included in `app/assets/agents/`. Codex uses the OpenAI Blossom from [OpenAI's brand assets](https://openai.com/brand/), and Claude Code uses the Claude mark from its [official documentation](https://code.claude.com/docs/en/overview). Those marks remain the property of OpenAI and Anthropic and are subject to their trademark rules.

<sub>[Back to the README](../README.md#further-reading)</sub>
