# iOS features missing on Linux

Source comparison: native White Noise iOS at [`d7037f1`](https://github.com/marmot-protocol/whitenoise-ios/commit/d7037f1477c25c33924e2ec8bfa8597546096e68) and White Noise Linux at `f742ded5`. This is a shortlist based on source, not a runtime audit of released builds.

| iOS | Linux |
| --- | --- |
| [Push notifications][push] can arrive while the app is not running and offer **Reply** and **Mark as read**. Chats can use [mentions-only alerts][mentions]. | [Desktop alerts](../app/notify.odin#L28-L54) require the app to be running, which includes running in the tray. Chats can be muted, but there are no notification actions or mentions-only mode. |
| [Biometric app lock][app-lock] has a configurable delay. A separate [privacy cover][screen-privacy] hides content in the app switcher and during recording or mirroring. | [Manual vault lock](../docs/features.md#privacy--data) requires the vault password to unlock. There is no biometric unlock, auto-lock timer, or capture cover. |
| [Scan profile QR codes][qr-scan] and [take photos or record video from the composer][camera]. | Linux can show [profile QR codes](../docs/configuration.md#deep-links-marmot), accept pasted profile links, and attach existing files. It does not use the camera. |
| [Automatic download rules][download-rules] vary by attachment type and connection. [Manage Storage][manage-storage] can remove downloaded attachments by chat, file, or age. | [Storage settings](../app/storage.odin#L227-L254) show the size of the attachment cache and can clear it as a whole. There are no equivalent download rules or targeted cleanup controls. |
| [Report eligible messages][report] inside the encrypted group or to the White Noise team, depending on eligibility. | Linux supports blocking but has no message reporting UI. |
| [Retry stalled chat sync or review a rejoin invitation][recovery] from the conversation. | Linux uses [MDK recovery](../docs/development.md#L85) and has a developer command to retry convergence. There is no equivalent in-chat recovery UI. |

## Partial gaps

- On iOS 26 or later, [hold the message field to dictate, then release to send][dictation]. [Linux dictation](../docs/stt.md#dictate-into-a-draft) puts the recognized text in the draft for review instead.
- iOS [loads received GIPHY links on tap by default][remote-gifs] and has a separate setting to load them automatically. Linux already has [GIF search and playback](../docs/gifs.md). Received GIPHY links follow the global link-preview setting rather than a GIF-specific control.

[push]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f1/docs/manual-tests.md#L1710-L1763
[mentions]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f1/docs/manual-tests.md#L1670-L1697
[app-lock]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f1/docs/manual-tests.md#L1629-L1650
[screen-privacy]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f1/docs/manual-tests.md#L1652-L1665
[qr-scan]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f1/whitenoise-ios/Settings/ShareAndConnectView.swift#L211
[camera]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f1/whitenoise-ios/Conversation/ConversationView.swift#L1215
[download-rules]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f1/docs/manual-tests.md#L249-L266
[manage-storage]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f1/docs/manual-tests.md#L491-L520
[report]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f1/whitenoise-ios/Group/GroupModerationView.swift#L73
[recovery]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f1/whitenoise-ios/Conversation/GroupRecoveryView.swift#L18
[dictation]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f1/docs/manual-tests.md#L268-L313
[remote-gifs]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f1/docs/manual-tests.md#L1378-L1391
