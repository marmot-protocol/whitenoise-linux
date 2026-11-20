#include <stddef.h>
#include "marmot.h"

/* The Odin binding reads only these prefixes of runtime-owned events. */
_Static_assert(sizeof(MarmotEvent_Tag) == 4, "event tag width");
_Static_assert(MARMOT_EVENT_GROUP_JOINED == 0, "group joined tag");
_Static_assert(MARMOT_EVENT_GROUP_STATE_UPDATED == 1, "group state tag");
_Static_assert(MARMOT_EVENT_MESSAGE_RECEIVED == 2, "message received tag");
_Static_assert(MARMOT_EVENT_PROJECTION_UPDATED == 3, "projection tag");
_Static_assert(MARMOT_EVENT_GROUP_EVENT == 4, "group event tag");
_Static_assert(MARMOT_EVENT_ACCOUNT_ERROR == 5, "account error tag");
_Static_assert(MARMOT_EVENT_AGENT_STREAM_ACTIVITY == 6, "agent stream tag");
_Static_assert(MARMOT_EVENT_WELCOME_DELIVERY_PENDING == 7, "welcome tag");
_Static_assert(MARMOT_EVENT_EPOCH_STALL_ESCALATED == 8, "stall tag");
_Static_assert(MARMOT_EVENT_GROUP_CHANGE_SUPERSEDED == 9, "superseded tag");
_Static_assert(MARMOT_EVENT_HISTORY_NOTICES_CHANGED == 10, "history notices tag");
_Static_assert(offsetof(MarmotEvent, GROUP_JOINED.account_id_hex) == 8, "body alignment");
_Static_assert(offsetof(MarmotEvent, GROUP_JOINED.group_id_hex) == 24, "group prefix");
_Static_assert(offsetof(MarmotEvent, GROUP_STATE_UPDATED.group_id_hex) == 24, "state prefix");
_Static_assert(offsetof(MarmotEvent, MESSAGE_RECEIVED.received.message.group_id_hex) == 32,
               "message prefix");
_Static_assert(offsetof(MarmotEvent, PROJECTION_UPDATED.update.update.group_id_hex) == 24,
               "projection prefix");
_Static_assert(offsetof(MarmotEvent, GROUP_EVENT.group_id_hex) == 24, "lifecycle prefix");
_Static_assert(offsetof(MarmotEvent, WELCOME_DELIVERY_PENDING.group_id_hex) == 24,
               "welcome prefix");
_Static_assert(offsetof(MarmotEvent, EPOCH_STALL_ESCALATED.group_id_hex) == 24, "stall prefix");
_Static_assert(offsetof(MarmotEvent, GROUP_CHANGE_SUPERSEDED.group_id_hex) == 24,
               "superseded prefix");

_Static_assert(offsetof(MarmotGroupDetails, mls_state) == 280, "group MLS state");
_Static_assert(offsetof(MarmotAppGroupMlsState, required_app_components) == 32,
               "required app components");
_Static_assert(offsetof(MarmotAppGroupMlsState, required_app_components_len) == 40,
               "required app component count");

/* Timeline media is now an outcome union, including rejected source slots. */
_Static_assert(sizeof(MarmotMediaAttachmentReference) == 96, "media reference stride");
_Static_assert(sizeof(MarmotMediaAttachmentOutcome) == 112, "media outcome stride");
_Static_assert(MARMOT_MEDIA_ATTACHMENT_OUTCOME_ACCEPTED == 0, "accepted tag");
_Static_assert(MARMOT_MEDIA_ATTACHMENT_OUTCOME_REJECTED == 1, "rejected tag");
_Static_assert(offsetof(MarmotMediaAttachmentOutcome, ACCEPTED.attachment_index) == 8,
               "accepted index");
_Static_assert(offsetof(MarmotMediaAttachmentOutcome, ACCEPTED.reference) == 16,
               "accepted reference");
_Static_assert(offsetof(MarmotMediaAttachmentOutcome, REJECTED.attachment_index) == 8,
               "rejected index");
_Static_assert(offsetof(MarmotMediaAttachmentOutcome, REJECTED.rejection.kind) == 16,
               "rejection kind");
_Static_assert(offsetof(MarmotMediaAttachmentOutcome, REJECTED.rejection.detail) == 24,
               "rejection detail");
_Static_assert(sizeof(MarmotTimelineMessageRecord) == 352, "timeline stride");
_Static_assert(offsetof(MarmotTimelineMessageRecord, media) == 224, "timeline media");
_Static_assert(offsetof(MarmotTimelineMessageRecord, poll) == 16, "timeline poll");
_Static_assert(sizeof(MarmotPollType) == 4, "poll type width");
_Static_assert(MARMOT_POLL_TYPE_SINGLE_CHOICE == 0, "single-choice poll");
_Static_assert(MARMOT_POLL_TYPE_MULTIPLE_CHOICE == 1, "multiple-choice poll");
_Static_assert(sizeof(MarmotPollOptionResult) == 24, "poll option stride");
_Static_assert(sizeof(MarmotPollProjection) == 88, "poll projection stride");
_Static_assert(offsetof(MarmotPollProjection, poll_type) == 24, "poll type");
_Static_assert(offsetof(MarmotPollProjection, participants) == 32, "poll participants");
_Static_assert(offsetof(MarmotPollProjection, local_selection) == 40, "poll selection");
_Static_assert(offsetof(MarmotPollProjection, ends_at) == 72, "poll deadline");
_Static_assert(offsetof(MarmotPollProjection, open) == 80, "poll voting state");
_Static_assert(sizeof(MarmotTimelineReplyPreview) == 128, "reply preview stride");
_Static_assert(offsetof(MarmotTimelineReplyPreview, media) == 88, "reply preview media");

_Static_assert(sizeof(MarmotChatListMessagePreview) == 160, "chat preview stride");
_Static_assert(offsetof(MarmotPresentedChatRow, draft_version) == 0, "borrowed draft version");
_Static_assert(offsetof(MarmotPresentedChatRow, preview) == 8, "presented preview alignment");
_Static_assert(sizeof(MarmotPresentedChatRow) == 392, "presented row stride");
_Static_assert(sizeof(MarmotAuditLogSettings) == 1, "audit enable flag only");
_Static_assert(offsetof(MarmotClientOptions, store) == 16, "host secret store");
_Static_assert(sizeof(MarmotClientOptions) == 40, "client options stride");
_Static_assert(sizeof(MarmotGroupSystemEvent) == 104, "system event stride");
_Static_assert(sizeof(MarmotAppMessageRecord) == 184, "raw message stride");
_Static_assert(offsetof(MarmotAppMessageRecord, has_moderation_grant) == 176, "source authority");
_Static_assert(offsetof(MarmotAppMessageRecord, invalidated) == 178, "invalidated event");
_Static_assert(sizeof(MarmotGroupAppComponent) == 24, "component stride");
_Static_assert(MARMOT_HOST_PERFORMANCE_OPERATION_LINUX_STARTUP_BEFORE_VAULT == 6,
               "host operation order");
_Static_assert(sizeof(MarmotMemberResolutionOutcome) == 16, "member outcome stride");
_Static_assert(sizeof(MarmotGroupCreationResult) == 24, "creation result");
_Static_assert(sizeof(MarmotInviteMembersResult) == 24, "invite result");
_Static_assert(MARMOT_MEMBER_RESOLUTION_STATUS_INCOMPLETE == 6, "member status order");
_Static_assert(sizeof(MarmotAuditLogSource) == 24, "audit source");
_Static_assert(sizeof(MarmotAuditOtlpConfigV5) == 40, "audit v5 config");
_Static_assert(offsetof(MarmotAuditOtlpConfigV5, allow_loopback_dev) == 32, "audit loopback");

#define ABI_SIZE(type, n) _Static_assert(sizeof(Marmot##type) == n, #type " size")
#define ABI_OFFSET(type, field, n)                                                                 \
    _Static_assert(offsetof(Marmot##type, field) == n, #type "." #field)
#define ACCOUNT_EVENT(tag, body, n)                                                                \
    _Static_assert(MARMOT_EVENT_##tag == n, #tag " discriminant");                                 \
    ABI_OFFSET(Event, body.account_id_hex, 8);                                                     \
    ABI_OFFSET(Event, body.account_label, 16)

ACCOUNT_EVENT(LINKED_DEVICES_CHANGED, LINKED_DEVICES_CHANGED, 11);
ACCOUNT_EVENT(KEY_PACKAGE_REFRESH_OVERDUE_CHANGED, KEY_PACKAGE_REFRESH_OVERDUE_CHANGED, 12);
ACCOUNT_EVENT(UNRECOGNIZED_SIGN_INS_CHANGED, UNRECOGNIZED_SIGN_INS_CHANGED, 13);
ACCOUNT_EVENT(COMPROMISE_WARNING_CHANGED, COMPROMISE_WARNING_CHANGED, 14);
ACCOUNT_EVENT(DEVICE_LINK_CHANGED, DEVICE_LINK_CHANGED, 15);
ACCOUNT_EVENT(RECOVERY_STATUS_CHANGED, RECOVERY_STATUS_CHANGED, 16);
ACCOUNT_EVENT(DEVICE_UNLINKED, DEVICE_UNLINKED, 17);
ACCOUNT_EVENT(CHAT_HISTORY_IMPORTS_CHANGED, CHAT_HISTORY_IMPORTS_CHANGED, 18);

ABI_SIZE(AccountSummary, 24);
ABI_OFFSET(AccountSummary, signed_out, 18);
ABI_OFFSET(AccountSummary, running, 19);
ABI_OFFSET(AccountSummary, unlinked, 20);
ABI_SIZE(LinkedDevice, 80);
ABI_SIZE(DeviceLinkEmoji, 16);
ABI_SIZE(NewDeviceLinkState, 24);
ABI_OFFSET(NewDeviceLinkState, COMPARING, 8);
ABI_OFFSET(NewDeviceLinkState, ENDED, 8);
ABI_SIZE(DeviceLinkPromptState, 24);
ABI_OFFSET(DeviceLinkPromptState, COMPARING, 8);
ABI_OFFSET(DeviceLinkPromptState, RATE_LIMITED, 8);
ABI_OFFSET(DeviceLinkPromptState, CANNOT_LINK, 8);
ABI_OFFSET(DeviceLinkPromptState, ADDED_ELSEWHERE, 8);
ABI_OFFSET(DeviceLinkPromptState, ENDED, 8);
ABI_SIZE(DeviceLinkPrompt, 48);
ABI_SIZE(DeviceGroupMoveView, 48);
ABI_SIZE(DeviceGroupMoveSibling, 24);
ABI_OFFSET(DeviceLinkSnapshot, new_device, 0);
ABI_OFFSET(DeviceLinkSnapshot, prompts, 8);
ABI_OFFSET(DeviceLinkSnapshot, prompts_len, 16);
ABI_OFFSET(DeviceLinkSnapshot, moves, 24);
ABI_OFFSET(DeviceLinkSnapshot, moves_len, 32);
ABI_OFFSET(DeviceLinkSnapshot, device_group_stalled, 40);
ABI_SIZE(UnrecognizedSignIn, 56);
ABI_SIZE(CompromiseWarningItem, 32);
ABI_SIZE(ChatHistoryImportState, 32);
ABI_OFFSET(ChatHistoryImportState, RECEIVING, 8);
ABI_OFFSET(ChatHistoryImportState, IMPORTED, 8);
ABI_SIZE(ChatHistoryImport, 40);
ABI_SIZE(HistoryImportSource, 16);
ABI_SIZE(BackupHistorySource, 32);
ABI_SIZE(HistoryImportProvenance, 40);
ABI_OFFSET(HistoryImportProvenance, DEVICE, 8);
ABI_OFFSET(HistoryImportProvenance, BACKUP, 8);
ABI_OFFSET(TimelineMessageRecord, imported_from, 336);
ABI_OFFSET(TimelineMessageRecord, history_import_provenance, 344);
ABI_SIZE(GroupEventKind, 48);
ABI_OFFSET(GroupEventKind, QUEUED_INTENT_REFUSED, 8);
ABI_OFFSET(GroupEventKind, GROUP_CHANGE_NOT_DELIVERED, 8);
ABI_OFFSET(Event, GROUP_EVENT.event, 32);
ABI_SIZE(GroupChangeNotDelivered, 48);
ABI_SIZE(SendSummary, 32);
ABI_OFFSET(GroupMutationResult, summary, 0);
ABI_SIZE(SignOutOutcome, 40);
ABI_SIZE(WipeOutcome, 72);
ABI_SIZE(LocalCleanupReport, 16);
ABI_SIZE(GroupLeaveFailure, 16);
ABI_SIZE(RelayFailure, 16);

int main(void) {
    return 0;
}
