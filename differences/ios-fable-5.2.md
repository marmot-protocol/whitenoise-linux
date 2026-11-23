# iOS features missing on Linux

Source comparison: White Noise iOS at [`d7037f147`](https://github.com/marmot-protocol/whitenoise-ios/commit/d7037f1477c25c33924e2ec8bfa8597546096e68) and White Noise Linux at `f742ded5`. This is a shortlist from reading both source trees, not a release or runtime audit.

| iOS | Linux |
| --- | --- |
| [Mute a chat for 1 hour, 8 hours, 1 day, 1 week, or always][mute-durations]. A chat can also notify for [only mentions][chat-notify-mode], and a [direct mention can still notify from a muted chat][muted-mentions]. | [Mute and Unmute](../app/rowactions.odin#L310) is a toggle with no duration. [`should_notify`](../app/notify.odin#L41) drops every message from a muted chat. The binding exposes [`muted_until_ms`](../marmot/marmot.odin#L489), but the app does not read it. |
| [Reply or mark read from a notification][notification-actions]. Previews have [three modes][preview-modes]: sender and message, sender only, or generic. | [Desktop notifications](../app/notify.odin#L90) show the full preview or a generic "New message". They have no actions. |
| [Report a user or a message][moderation-report] to the group or to the White Noise team. [Report details][message-reports] show what was filed. | No report control. The binding carries only the [moderation error codes](../marmot/marmot.odin#L126). |
| [View votes][poll-votes] lists who chose each poll option. | Polls show [vote and voter counts](../app/polls.odin#L162) only. |
| [Quarantined groups][quarantined] lists stored groups that failed to load and retries them without deleting history. A chat that stops syncing shows a [Retry banner][sync-retry]. | No equivalent for either. |
| [A warning before a group change][change-advisory] when this device may be behind, or when the last change has not reached every relay. You choose to wait or continue. | No equivalent. |
| The composer shows [how many characters a draft is over the limit][over-limit], and a rejected send reads [Message too long][too-long]. | No length notice in the composer. |
| [Auto-download per media type][auto-download] (photos, audio, videos, files): never, Wi-Fi only, or Wi-Fi and cellular. [Sent media quality][media-quality] is Standard or High. | Neither setting exists. |
| [Select several chats][chat-selection] to archive or unarchive them together, or to [leave them in one step][bulk-leave]. | [Row actions](../app/rowactions.odin#L309) apply to one chat at a time. |
| After an nsec sign-in, a [setup checklist][setup-check] finds the account's relay lists, offers a repair, and warns about other installations before it publishes a key package. | Sign-in [checks the key with the relays](../app/loginpane.odin#L364). [Republish relay lists](../app/network.odin#L229) is in Network settings, after sign-in. |
| [Scan a QR code][qr-scanner] to add a contact, or to [import an nsec][nsec-scanner]. | The app [shows QR codes](../app/profile_pane.odin#L513) and cannot read them. |
| [Spanish, Finnish, French, Portuguese, Russian, Turkish, and Chinese (Simplified and Traditional)][languages], beside English, German, and Italian. | [English, Italian, German, Japanese, and Korean](../app/i18n.odin#L13). iOS has no Japanese or Korean. |

## iOS platform integrations

- [App lock][app-lock] uses Face ID, Touch ID, or the passcode, and locks immediately or 1, 5, or 15 minutes after you leave the app. Linux has [manual vault lock](../docs/features.md#privacy--data) with password unlock, and no timer.
- [Hide Sensitive Content][screen-privacy] covers the app in the app switcher and during screen recording. Linux has no equivalent.
- APNS wakes the [notification extension][notification-service] while the app is closed. Linux notifies only while it runs, which [Close to tray](../app/settings_pages.odin#L883) keeps it doing.
- [Donate][donate] takes one-time and monthly donations through Apple Pay. Linux has no donation page.
- iOS asks for a [one-time terms agreement][terms] before sign-in or sign-up. Linux does not.

For Linux, start with timed mute and mentions-only alerts. The binding already exposes `muted_until_ms`, and mentions-only alerts are on the Android list too.

[mute-durations]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Chats/ChatMuteAction.swift#L4
[chat-notify-mode]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Group/ChatNotificationsView.swift#L27
[muted-mentions]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/Shared/MutedChatMentionsStore.swift#L3-L12
[notification-actions]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/Shared/NotificationActionCategory.swift#L9-L10
[preview-modes]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/Shared/NotificationPreviewMode.swift#L11-L16
[moderation-report]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Group/GroupModerationView.swift#L21-L32
[message-reports]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Conversation/MessageReportsView.swift#L5
[poll-votes]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Conversation/PollVotesSheet.swift#L6
[quarantined]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Settings/QuarantinedGroupsView.swift#L39
[sync-retry]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Conversation/GroupRecoveryView.swift#L145
[change-advisory]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Group/GroupChangeAdvisory.swift#L25-L39
[over-limit]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Conversation/ComposerBar.swift#L1275
[too-long]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Conversation/OutgoingSendSizeRejection.swift#L96
[auto-download]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Core/MediaAutoDownloadPolicy.swift#L8-L60
[media-quality]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Core/MediaQuality.swift#L17-L19
[chat-selection]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Chats/ChatListSelection.swift#L9-L10
[bulk-leave]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Chats/ChatListBulkLeaveState.swift#L7
[setup-check]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/docs/manual-tests.md#L1050-L1075
[qr-scanner]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Profile/QRScannerView.swift#L9
[nsec-scanner]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Onboarding/PrivateKeyQRScanner.swift#L9
[languages]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/Shared/AppLanguage.swift#L5-L15
[app-lock]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Core/AppLock.swift#L6-L19
[screen-privacy]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/docs/manual-tests.md#L1652-L1668
[notification-service]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/NotificationServiceExtension/NotificationService.swift
[donate]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Settings/DonateView.swift#L4
[terms]: https://github.com/marmot-protocol/whitenoise-ios/blob/d7037f147/whitenoise-ios/Onboarding/WelcomeView.swift#L61-L62
