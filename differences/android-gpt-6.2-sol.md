# Android features missing on Linux

Source comparison: native White Noise Android at [`fc08eebe9`](https://github.com/marmot-protocol/whitenoise-android/commit/fc08eebe912765e3dee50561910e276011017e23) and White Noise Linux at `f742ded5`. This is a shortlist, not a release or runtime audit.

| Android | Linux |
| --- | --- |
| [Reply, react, or mark read from a notification][notification-actions]. Android also has [mentions-only alerts and per-person overrides][notification-settings] and [scheduled notification profiles][notification-profiles]. | [Desktop notifications](../app/notify.odin#L81) with sound and preview toggles and per-chat mute. No notification actions or app-level schedules. |
| [Smart folders][smart-folders] combine nested rules and exclusions. Conditions include unread mentions, pending sends, and muted chats. | [Automatic folders](../app/folder_rules.odin#L27) use a flat match-all or match-any rule list. |
| [Keep on screen][kept-messages] holds selected messages in a floating card for the session. | No equivalent. |
| [Transfer group administration][transfer-admin] in one action, or [disband an eligible group][disband] for everyone. | [Promote, demote, and step down](../app/confirm.odin#L116) are separate actions. There is no disband control. |

## Android platform integrations

- [Amber (NIP-55)][amber] signs through a local Android signer. Linux already supports [NIP-46 remote signing](../docs/features.md#identity--accounts).
- Android has [home-screen chat widgets][widget] and [receives text and files from other apps through the share sheet][share]. Linux has no equivalent integrations.
- [App lock][app-lock] can lock after a delay and unlock with Android device authentication. Linux has [manual vault lock](../docs/features.md#privacy--data) with password unlock.

For Linux, start with notification actions and mentions-only alerts. Both apply to desktop notifications without copying Android's interface.

[notification-actions]: https://github.com/marmot-protocol/whitenoise-android/blob/fc08eebe9/app/src/main/java/dev/ipf/whitenoise/android/notifications/NotificationInteractionFactory.kt#L35
[notification-settings]: https://github.com/marmot-protocol/whitenoise-android/blob/fc08eebe9/docs/manual-release-testing.md#L558-L561
[notification-profiles]: https://github.com/marmot-protocol/whitenoise-android/commit/451357720
[smart-folders]: https://github.com/marmot-protocol/whitenoise-android/blob/fc08eebe9/app/src/main/java/dev/ipf/whitenoise/android/state/SmartFolderFilter.kt#L10
[kept-messages]: https://github.com/marmot-protocol/whitenoise-android/blob/fc08eebe9/app/src/main/java/dev/ipf/whitenoise/android/ui/conversation/messages/KeptMessagesController.kt#L13
[transfer-admin]: https://github.com/marmot-protocol/whitenoise-android/blob/fc08eebe9/docs/manual-release-testing/cases/GRP-008.md
[disband]: https://github.com/marmot-protocol/whitenoise-android/blob/fc08eebe9/app/src/main/java/dev/ipf/whitenoise/android/ui/group/GroupDisbandControls.kt#L33
[amber]: https://github.com/marmot-protocol/whitenoise-android/blob/fc08eebe9/docs/manual-release-testing.md#L145-L147
[widget]: https://github.com/marmot-protocol/whitenoise-android/blob/fc08eebe9/app/src/main/AndroidManifest.xml#L158-L166
[share]: https://github.com/marmot-protocol/whitenoise-android/blob/fc08eebe9/app/src/main/AndroidManifest.xml#L200-L209
[app-lock]: https://github.com/marmot-protocol/whitenoise-android/blob/fc08eebe9/app/src/main/java/dev/ipf/whitenoise/android/state/AppLockController.kt#L45
