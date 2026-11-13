# Whip inside White Noise

On Linux, native builds detect an executable `../whip/build/whip` and its
built Ghostty library. Build Whip first, then rebuild White Noise. While that
executable is installed, its projects appear inside Chats with a terminal
icon, directory, tab count and selected accent. White Noise attaches to Whip's
`default` session, starting its server if needed.

Chats and terminals share pinned-first, recent-activity ordering, search,
Unread and keyboard cycling. The Whip filter shows only terminals. Right-click
a terminal to pin it or move it to a folder. Grouped view and the Folders board
use the same assignments; an Is Whip folder rule files projects automatically.
Terminal recency follows your input and newly created projects, tabs and panes.
Opening a terminal does not move it up the list. Background output and
notifications do not change its recency either. Equal timestamps use stable
project IDs, so catalog refreshes do not shuffle tied rows. Recency is saved by
folder; activity while White Noise is detached has no timestamp available from
Whip.

Choose New terminal from the New chat chooser to pick a project folder and
open it. White Noise owns the tab strip, pane headers and draggable splitters.
Each pane has its own Whip rendering context inside its assigned slot. Tab
titles follow standalone Whip's naming rules, including live terminal titles
and emoji. Tabs and panes can be opened and closed from their native controls.
Project identity, tabs and the new-tab button share one compact header, using
the same styling as chats. Hover the project name for its full folder path.
Focus borders identify the active terminal. Split and docked titlebars are
hidden until you hover their top edge. Their names and controls overlay
the terminal without resizing it. Floating titlebars stay visible.
Keyboard tab changes and window resizing keep the active tab in view. The
ordinary mouse wheel browses the tab strip horizontally without changing tabs.
Drag a tab to reorder it. The accent marker shows where it will land; holding
it at either edge scrolls the strip. Drop outside the strip or press Escape
to cancel. Reordering keeps the selected terminal open, and numbered and
previous/next shortcuts follow the displayed order. White Noise saves this
order per account and project for the same running Whip server; standalone
Whip's order is unchanged.

Right-click a terminal and choose Edit project, or click its name in the
header, to change its name and root folder. Enter an absolute path or one
starting with `~/`. White Noise saves these overrides locally; running
shells and standalone Whip are unchanged. An explicit root stays fixed when
the first tab changes directories. Correcting it preserves pins, folder
assignments, avatars and saved tab order. Folder validation runs in the
background and keeps your draft open if the path needs correcting.

Appearance zoom scales terminal text along with the rest of the interface.
Fonts are rerasterized at the host's pixel scale rather than stretching an old
image. Configured terminal fonts and per-pane font-size shortcuts still apply.

One observer connection carries session snapshots and terminal output. Pane
contexts reuse those terminals instead of attaching another full-session
history stream. Snapshots decode in the background, with at most two decoders
at once. Subsequent output and resize events apply after that snapshot is restored.

Unchanged clicks reuse the terminal's cached frame. Focus changes repaint the
affected panes without invalidating unrelated terminals or reloading fonts.
Whip configuration refreshes when the host window regains focus. Opening
several panes initializes one native context per frame; font refreshes share
that budget. The focused pane initializes first. Hidden panes refresh when
shown. Pending panes keep
their opening progress visible until ready. Loading feedback stays in overlays,
including while tabs or splits are pending, so progress indicators do not
change terminal geometry.

Choose Float in a pane header to keep that shell above chats as you navigate.
Drag the header to move it; use the corner grip to resize it. Dock to chat
attaches it to the current conversation, beside the chat on wide windows or
below it on narrow ones. That pane appears only with its chat and account.
Drag the divider to give the chat or terminal more room. Side-by-side widths
and stacked heights are remembered separately.
Choose Float to detach it again, or Return to project to restore its original
slot and open its tab with shell input focused, without restarting it.
Selected tabs, floating positions and chat docks survive closing White Noise
and are scoped to your account. Saved panes reconnect only to the same running
Whip server, so a reused pane number cannot attach a different shell to a chat.
The startup restore setting also reopens your last selected terminal. Typing
or navigating while the catalog loads takes precedence over that restoration,
and restoring a terminal does not advance its recent-activity position.

Whip's keyboard shortcuts work while its content has focus. Ctrl+T and Ctrl+W
open and close tabs; Ctrl+Shift+Left/Right switches tabs. Ctrl+N creates a
project in the focused pane's directory. Ctrl+Alt+V and Ctrl+Alt+Minus split
panes. Pane focus, zoom, resize,
find, clipboard and rename shortcuts keep Whip's bindings. Ctrl+Alt+/ opens
Whip's shortcut help; Ctrl+Alt+Q returns to the inbox without stopping shells.
Ctrl+Shift+Up/Down moves between all visible chats and terminals, whether you
start in a chat or a terminal. It follows the sidebar's pin and folder order,
respects filters, skips collapsed folders, and wraps at either end. Ctrl+Tab
and Ctrl+Shift+Tab use the same order. Keyboard navigation scrolls the selected
row into view without taking over later wheel scrolling. Navigation and typing
queued together are processed in order, so text reaches the destination chat or
terminal. On a first visit, terminal keystrokes wait for that pane's native
input context instead of disappearing during initialization. Sidebar search
keeps the terminal visible while directing text input to the search field.

Ctrl+Alt+A toggles the Android emulator panel beside the focused terminal.
Click and drag on its screen to send touches. The header buttons send Back,
Home and Recents or rotate the device. Drag the panel's left edge to resize it.

Returning to a conversation restores the message and position you were reading
in its main timeline, including after working in Whip. Reading positions are
kept per account and conversation for the current unlocked session. A chat left
at the newest message still follows the newest messages. Search results, reply
jumps and Jump to latest take precedence over the saved reading position.
Click a reply quote to jump to its original message. If the original isn't
loaded in the current view, a brief notice explains why the view didn't move.

Every project starts with a crop-circle avatar derived from its folder.
Click the avatar to choose and crop a picture, or restore its crop circle.
The choice is saved by folder, so renaming or recreating the project keeps
its picture. Pictures are copied into the config directory's `whip-avatars/`
folder; the original image file is not needed afterward.

Bells and terminal notifications from unseen panes show the same animated
unread badges as chats, on their tab, project and Chats navigation button.
Viewing a pane clears its waiting state; a pane hidden by zoom stays unread.
Desktop alerts use your White Noise notification, sound and preview settings.
On narrow windows, Back returns to the shared inbox. Switching pages or closing
White Noise leaves the session's shells running.

Whip is optional. Builds without that sibling checkout and cross releases
omit the integration. Native build scripts stage its Odin bridge from
`whip-embed/`; they do not build or modify the sibling checkout. An isolated
source copy under `build/whip-embed/` applies the host-notice and host-control
patches so navigation uses White Noise controls and terminal notifications
follow its settings without duplicate Whip alerts. The host-render patch
preserves cached terminal frames across unchanged input and metadata updates.
The host-source patch shares terminal streams and keeps snapshot decoding off
the UI thread without changing the installed server or Ghostty ABI. The
host-scale patch defers font reloads to their owning GL context and follows
White Noise zoom without multiplying display density twice.
