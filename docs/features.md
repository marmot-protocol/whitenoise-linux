# Feature tour

Everything White Noise Linux does, grouped by area. The [README](../README.md) has the short version.

## Messaging

- One-to-one and group chats, end-to-end encrypted through Marmot's MLS, with sealed-sender invites over NIP-59.
- Developer mode shows a clickable MLS badge in chat headers when space allows. Open it to inspect and copy the group ID or read the current encryption revision (MLS epoch).
- New chat opens a searchable contact picker. Choose a contact or select New group to set its name and photo. Groups require a first member: type to filter your contacts and select one, or paste a Nostr address.
- Group settings show name, description, photo, disappearing-message, and issue-tracking controls only to admins. The rename field starts with the current group name. Other members can view the group's name, description, photo, and current disappearing-message timer in full units, such as "90 days".
- Only group admins can promote, demote, or remove members. Nicknames change your local labels and remain available to other members.
- Markdown bodies (with typeset `$` math blocks), reactions, replies, edits with history, forwarding, and search.
- Click Send or press Enter to send; Shift+Enter inserts a new line. Editing a message changes Send to Save. Hover over the attach, emoji, and microphone buttons for their labels.
- Poll creation keeps your draft open and explains a missing question or fewer than two nonblank options. Multiple choice is an on/off switch; Create is the primary action and Cancel is secondary.
- Linked Nostr highlights (kind 9802, NIP-84) put the selected passage in large type, with quieter context, avatar bylines, and compact source tiles. Cards start with the highlighter's byline, without a kind label. Source tiles identify the domain, event, or structured source. Source links and the full-width Open in client button use the external-link guard. Read more expands the quotation, context, and commentary together. Media-only highlights retain their source tiles.
- Markdown bodies preserve single newlines. HTTP(S) links keep their labels and destinations. Hover shows the URL; opening a link uses the external-link guard. Long addresses in the guard scroll horizontally without breaking path words. Scroll over the address to read it in full. Chat-list previews show reading text without Markdown markup.
- Pasted `https://njump.me/<reference>` and `http://njump.me/<reference>` links render like `nostr:` references: profile chips for `npub`/`nprofile`, event cards for `note`/`nevent`/`naddr`. Event cards use your configured Nostr web client.
- Linked Nostr pull requests (kind 1618) and Git issues (kind 1621, NIP-34) show their own icon and label, a bold subject when present, separate author and timestamp lines, and a Markdown description. Long subjects wrap to three lines with an ellipsis. A full-width Open in client button uses your configured Nostr web client.
- Linked Git patches (kind 1617, NIP-34) show the mail subject, author, repository, revision or series marker, and file/addition/deletion counts. The diff preserves code as literal monospace text, with tinted additions and deletions. Read more expands the description and diff; inline diffs stop at 1,000 wrapped rows, with the complete patch available through Open in client. Cover letters show their subject and description without invented change counts.
- Markdown timestamps such as `<t:1791280800:F>` display in your current timezone with a clock icon. Hover over a timestamp to see its absolute local date/time and original token. Styles `t`, `T`, `d`, `D`, `f`, `F`, `s`, `S`, and `R` cover time, date, combined, and live relative labels; omitting the style selects `f`. Absolute labels follow your Date format and Time format settings and the app language, like the rest of the app's dates. Invalid tokens stay literal, and unsupported dates remain readable tokens.
- Day dividers say Today for the current local day and update at midnight. The chat list shows the time for today, Yesterday, then the date. Changing the Date format, Time format or language updates every visible date at once, including the open chat.
- Search all chats takes start and end days in your local calendar, written the way the app shows dates (`Jun 12`, `12 Jun 2026` or `2026-06-12`); without a year, the current one is used. Results are dated the way the chat's day dividers are.
- Settings > Appearance sets the message line limit. Messages and event cards collapse after 6 lines by default; 0 shows them in full without Read more.
- Settings > AI agents offers setup prompts for Hermes, OpenClaw, OpenCode, Codex, and Claude Code. Review and copy a prompt containing your active account's full public npub, then paste it into an agent you run and trust. Escape from a setup card returns to the connector list. Copy prompt is the main action, with a secondary Copy public key button and links to connector documentation. White Noise does not install anything or share your private key.
- Ctrl+K searches literal text in locally stored history, including archived chats. Filter by chat, sender, local date range, or attachment type, and use More results to page through matches. Opening a result returns to Chats and loads older history when needed. Closing search preserves its query and results; switching accounts clears them. Unsynced messages are not searched.
- Export the loaded chat window as HTML or Markdown from the members panel. HTML prepares embedded images in the background and shows image progress before opening the save dialog. Unavailable images appear as notes in the transcript. Leaving the chat or changing accounts discards an unfinished export.
- Emoji search accepts names and shortcodes, such as `100` for hundred points and `thumbsup` for thumbs up. Shortcodes work with or without surrounding colons.
- The emoji picker's eight most recent choices survive app restarts, newest first.
- Settings > General > Messaging > Custom emoji browses recent [NIP-51 kind-30030 emoji sets](https://github.com/nostr-protocol/nips/blob/master/51.md) from your event-fetch relays. Sets from your contacts come first, with A-Z ordering within each group and a saved Contacts only filter. Sets with no valid emoji stay hidden. Each row shows artwork and an author mention chip. Search by title, author, or shortcode, then open a set to preview it. Import the whole set or use the + button beside one emoji. Previews appear as each download finishes. Imported emoji keep their set title and verified author after a restart. Imports preserve existing shortcodes and report skipped entries and failed downloads. Browsing previews and importing contact HTTPS image hosts; PNG, JPEG, GIF, and WebP are supported when the image decoder accepts them.
- Custom `:shortcode:` emoji use NIP-30. The image goes out as an encrypted attachment, and the message carries an `["emoji", shortcode, url]` tag pointing at that attachment's Blossom URL. Reactions work the same way: a `:shortcode:` reaction carries its own `imeta` and emoji tag. Forwards keep the tags. MDK's `marmot_send_tagged_media` and `marmot_react_with_media` send them, and MDK keeps the media key for reaction images the way it does for chat media.
- A durable on-disk send queue, so messages written offline aren't lost and go out on reconnect.
- The Forward picker shows the message's first line, or its first attachment's filename, above the destination filter. Forwarded attachments download and prepare in the background. A status strip names the destination and stays visible through preparation and sending, even if you switch chats. Failed forwards can be retried from the destination chat. A confirmation names the destination after every part succeeds; a partial or cancelled forward does not report full success.
- Native Linux builds translate messages and audio transcriptions on your device with
  [TranslateGemma 4B Q4_K_M](https://huggingface.co/mradermacher/translategemma-4b-it-GGUF).
  Enable it in Settings > General > Language > Message translation, choose
  the target language, then use Translate in a message's context menu.
  For audio, finish a transcription and use Translate below its expanded text.
  Show original and Show translation switch the displayed text without
  changing the stored message or original transcription. Automatic translation
  processes received messages and expanded, completed audio transcriptions as
  you read them. It does not start transcription. The first translation downloads about 2.5 GB
  of model files; later translations work offline. Enabling accepts the
  [Gemma terms](https://ai.google.dev/gemma/terms) and
  [prohibited use policy](https://ai.google.dev/gemma/prohibited_use_policy).
  Source detection runs locally with fastText. If it cannot identify the
  language, choose the source in settings. Results stay in session memory
  and are discarded when you change chats, accounts, or language settings.
  Messages beyond the model's input or output token limits fail rather
  than return a truncated translation.
- Per-chat unread tracking, surfaced as rail badges.
- Deleting a chat folder requires confirmation, from both Settings and its context menu. Only the folder is removed; its chats stay in your chat list.
- Folder rules file chats automatically: name includes a word, has a member (npub), has fewer or more than N people (you included), or has unread messages. Each folder matches all of its rules or any one of them. A chat goes to the first folder, in folder order, whose rules match. A chat you move by hand stays in that folder; choosing "Follow folder rules" in the move dialog hands it back to the rules. Member rules read each group's member list on every chat-list refresh, and only while such a rule exists.
- Settings > Folders lists every chat under the folder it files into. Drag a chat onto a folder (Unfiled included) to keep it there, or drag a folder header to reorder folders. Chats placed by hand show a checked box; clearing it hands the chat back to the rules. In Recent mode, every folder appears beside Chats, Unread, Groups, and Whip as a filter, keeping recent activity order within the selected folder. In Grouped mode, empty folders stay out of the chat list sidebar.

## Media

- Drag one or more files into the open chat to stage attachments. Files prepare in the background, with image thumbnails when available. Remove unwanted files with the × on each chip; press Enter when preparation finishes to send. Drops outside the conversation or over a modal do not attach files.
- [Personal stickers and Sonar sticker packs](stickers.md); packs come from MDK and sync across your devices, with pack previews from received stickers.
- Image albums, inline video (libmpv), voice messages, and a preview modal that reads PDFs (poppler), archives (libarchive), STL, OBJ, FBX, and GLB models, and source files with syntax highlighting.
- Enable Speech to text in Settings to transcribe audio attachments locally. M4A files use the audio card and its Transcribe button, including attachments labeled `video/mp4` by another client.
- Direct JPG, PNG, GIF, and WebP links show inline cards with the image above its clickable URL. Messages ending with two or more standalone image links show them as one grid. Four portrait images use two rows of two, for both links and attachments. Click a grid image to browse the loaded images in the lightbox. Link previews are on by default; turn them off in Settings > Advanced > Security & privacy to stop new automatic preview requests, including supported-site cards. Preview hosts can see your IP address. Attachment downloads are unaffected.
- Locations shared from the Android app (`Location: https://maps.google.com/maps?q=<lat>,<lon>`) show an OpenStreetMap card in place of the Google link. Pasted OpenStreetMap, Kagi Maps, Apple Maps, and Google Maps links that name a point or a map view get the same card, opened at the link's zoom: markers, place pages, search pages, and plain map views (for example `https://www.openstreetmap.org/?mlat=0&mlon=0#map=12/0/0`, `https://kagi.com/maps/#14.58/0/0`, or a Google `/maps/place/…/@lat,lon,17z` link). Google's country domains such as google.it are not recognized. Drag the map to pan, scroll or use the zoom buttons to zoom, and Recenter to return to the pin. The card names the town and country and offers Copy coordinates and an Open in link. Settings > Advanced > Open locations in picks the site that link opens: OpenStreetMap (the default), Apple Maps, Kagi Maps, or Google Maps. That site receives the location; the map on the card always comes from OpenStreetMap. Tiles come from tile.openstreetmap.org and place names from Nominatim, which receives the coordinates rounded to three decimals; the app never contacts Google on its own. The first card asks before loading anything; Settings > Advanced > Location maps changes the answer later, and turning off link previews hides the cards. Tiles are cached in the encrypted media cache under keyed file names, up to 1 GB with the oldest fetches removed first, and are fetched again after a week.
- To send a location, use the pin button beside the composer. Drag or zoom the map to choose a point, or choose Use current location to request permission through the Linux desktop's location portal. Review the pin, then choose Send location. Current location needs a desktop portal backend and location service; if unavailable or denied, pick a point manually. Sending keeps your composer draft and staged attachments and uses Android's location message format.
- Signal call links (`https://signal.link/call/#key=…`) and Jitsi Meet room links show a call card styled after that app, with a join button and a line saying the call runs outside White Noise. meet.jit.si rooms are recognized from the URL. For any other host, a one-segment room link (`https://meet.example.org/Standup`) prompts one request to `https://<host>/external_api.js`, the script every Jitsi Meet server publishes; hosts that serve it get the card, and the answer is kept until the app restarts. Clicking goes through the external-link guard like any other link. If Signal Desktop or the Jitsi Meet desktop app is registered for `sgnl://` or `jitsi-meet://`, the call opens there directly; otherwise it opens in your browser. Turning off link previews shows plain URLs and stops the Jitsi host requests.
- PDFs have fullscreen controls on attachment tiles and in previews. The fullscreen modal fills the app window without changing desktop fullscreen. Pages fit the window and render at its pixel density, with previous/next controls. Exit fullscreen returns to the preview; Escape closes it.
- Attachments travel over Marmot's encrypted MIP-04 path. Profile pictures are the one deliberate exception: they go out publicly via Blossom.
- GLB attachments open as static 3D scenes with orbit, zoom, and the model inspector. The viewer reads node transforms, material factors, and embedded PNG/JPEG textures on UV0. GLB animation, skinning, morph targets, vertex colors, and Draco/meshopt compression are not supported. External resources are never fetched; translucent materials use alpha cutouts.

## Games

- A `.nes` attachment, or an archive holding nothing but one `.nes` file, shows a cartridge tile with a Play button. The game runs in a modal: arrow keys move, X is A, Z is B, Enter is Start, Shift is Select, and Escape closes it. Supported boards are mappers 0, 1, 2, 3, 4 and 7 (NROM, MMC1, UxROM, CNROM, MMC3, AxROM). There are no battery saves, save states or gamepad input.

## Identity & accounts

- Several accounts at once, with local nsec keys and NIP-46 remote signers side by side. Connected accounts receive messages in the background.
- The app opens on the account you used last. For a remote-signer account it starts on a local one and switches once the signer connects.
- The trash button on an account row (the Accounts switcher or the Profile page) removes that account from this device after you confirm. Its keys and local chats are deleted; its groups are not notified, so other members still see it.
- Connect with a `bunker://` link or scan/copy a `nostrconnect://` pairing link. Approve requests in your signer; pending operations show their status and approval links.
- People lists people you follow. Starting a chat does not add someone to People. Private local-only nicknames, an archive, and npub QR codes are also available.
- Profile popups have a Message button. It opens your existing DM, including an archived DM without restoring it, or creates a new DM if none is reusable.
- Your profile is public. The optional Verified address field holds a Nostr identifier (NIP-05), not your email address.
- Empty display name, about, and Lightning inputs show a muted "Not set" hint. Empty profile summary values also say "Not set".
- Profiles without a loaded name show a deterministic adjective and animal, such as "Magnetic Panda", derived from their public key. Published names replace it when loaded; local nicknames take precedence. The npub remains visible on profile cards.
- Import and export contacts as CSV or JSON from the contacts rail. Imports skip existing contacts and duplicate npubs, restore private nicknames and blocked state, and report added, skipped, and failed records. Published profile names still come from Nostr.

## Look & feel

- Thirty-five bundled themes and five accent colors, all data-driven from `themes/*.toml`. Each pack defines its accent labels with `accent-name-1` through `accent-name-5`, matching the order of `accent-base`. The theme editor labels accent names separately from accent colors and preserves both. Drop your own pack in the data dir.
- AMOLED uses black and white theme colors and hides its accent chooser. A whole-view pass reduces color saturation to 25%, including avatars, emoji, and media.
- Film Noir adds visible, moving film grain to the whole view, including photos and video. Reduce motion freezes the grain; the filter adds no contrast or vignette.
- Settings > Appearance > Center the conversation centers the message timeline and composer in a column at most 720px wide. Settings search accepts both "center" and "centre". Narrower windows use the available width; turning it off restores full width.
- Settings > Appearance puts controls, the theme gallery, and a live conversation preview side by side on wide windows. Medium windows put controls beside stacked themes and preview; all three panels scroll independently. Narrow windows stack them on one page. The preview uses the normal chat renderer with a fictional marmot conversation, not your messages or draft. It is static: its header and messages do not react to the pointer, and it has no composer.
- The theme gallery has separate Dark and Light views and collection headings. Settings search finds the picker by any loaded theme's displayed name, including custom packs, without changing your theme. Hover over a tile to preview it. Leaving the tile or pressing Escape restores your theme; clicking saves the choice.
- The Sidecar collection contains all 21 themes from [dmnyc's Sidecar](https://github.com/dmnyc/sidecar). Selecting one shows its source credit on the page and the selected tile. Collection headings have no links.
- Royale and Royale Dark use XP Royale's blue chrome with pearl or charcoal surfaces and bevelled controls.
- Chalkboard and Crayon use bundled Kalam lettering at 125%, textured surfaces, fixed rough strokes, and sketched avatars. The Hand-drawn filter toggle in Appearance turns the material effect off without changing the palette or lettering size. This filter preference is shared by both themes.
- Chalkboard erases the photo to reveal its identity fingerprint on avatar hover, then redraws the photo when the pointer leaves. Other themes keep the swivel reveal.
- Terminal uses a fixed green accent and hides its accent chooser.
- Button text derives separately for each accent color using sRGB contrast. Custom packs can set `on-accent` to override the text color for all five accents.
- English, Italian, German, Japanese, and Korean, switchable at runtime, including search dialogs, theme notifications, and confirmation errors.
- Native desktop notifications, a command palette, and full keyboard navigation.
- Chat transitions follow the conversation, not its position in the list. New messages can reorder the list without sliding the open chat.
- Reduce motion hides animated synth, dust, scan, and wave backdrops, including the vault gate's synth backdrop. Static decorations remain visible.

## Mobile Linux

Narrow windows show one view at a time, with full-width chat and contact
lists. Use the bottom navigation to switch pages and Back to return from
a conversation. Back keeps your draft and staged attachments. Settings,
forms, dialogs and media controls reflow or scroll to fit the window.

Tap or long-press a message for its actions, and long-press a chat for
its row menu. A conversation's header holds Back, search and a menu with
files, mentions, settings and members. The Chats menu holds Lock now and
the command palette. The status bar appears only while you are offline or
connecting. Rotating a phone keeps the text size; landscape gains room and
the navigation drops its labels. Drag overflowing toolbars and choice rows
sideways and page content vertically. Reduce motion keeps direct finger
scrolling but disables the fling. Tap the composer to activate platform
text input; opening a conversation does not raise the on-screen keyboard.
On short screens, navigation gives the active view more room; Back restores
it. Short conversations also hide the status readout, but retain progress
and error banners.

Linux ARM64 packages use the same interface (see [Install](install.md)).
The compositor supplies the on-screen keyboard through SDL's platform
text-input support.

## Privacy & data

- One password-encrypted vault holds every secret (see [Security model](security.md)).
- Lock now in the status bar (the Chats menu on phones) or command palette closes the runtime, clears the vault key and session state, and returns to the password gate without closing the window. Unlock with your vault password to reconnect.
- Encrypted backup and restore for settings, drafts, custom emoji, and themes. Account keys and message history are not included.
- Opt-in OTLP metrics and audit logging, both off until you turn them on in Settings.

## Third-party marks

The AI agent icons identify third-party products, not endorsements. Hermes artwork comes from [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent), OpenClaw's mark from [openclaw.ai](https://openclaw.ai), and OpenCode's mark from its [brand assets](https://opencode.ai/brand); their MIT license notices are included in `app/assets/agents/`. Codex uses the OpenAI Blossom from [OpenAI's brand assets](https://openai.com/brand/), and Claude Code uses the Claude mark from its [official documentation](https://code.claude.com/docs/en/overview). Those marks remain the property of OpenAI and Anthropic and are subject to their trademark rules.
