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
_Static_assert(MARMOT_EVENT_GROUP_CHANGE_SUPERSEDED == 9, "last event tag");
_Static_assert(offsetof(MarmotEvent, GROUP_JOINED.account_id_hex) == 8, "body alignment");
_Static_assert(offsetof(MarmotEvent, GROUP_JOINED.group_id_hex) == 24, "group prefix");
_Static_assert(offsetof(MarmotEvent, GROUP_STATE_UPDATED.group_id_hex) == 24, "state prefix");
_Static_assert(offsetof(MarmotEvent, MESSAGE_RECEIVED.received.message.group_id_hex) == 32, "message prefix");
_Static_assert(offsetof(MarmotEvent, PROJECTION_UPDATED.update.update.group_id_hex) == 24, "projection prefix");
_Static_assert(offsetof(MarmotEvent, GROUP_EVENT.group_id_hex) == 24, "lifecycle prefix");
_Static_assert(offsetof(MarmotEvent, WELCOME_DELIVERY_PENDING.group_id_hex) == 24, "welcome prefix");
_Static_assert(offsetof(MarmotEvent, EPOCH_STALL_ESCALATED.group_id_hex) == 24, "stall prefix");
_Static_assert(offsetof(MarmotEvent, GROUP_CHANGE_SUPERSEDED.group_id_hex) == 24, "superseded prefix");

/* Timeline media is now an outcome union, including rejected source slots. */
_Static_assert(sizeof(MarmotMediaAttachmentReference) == 88, "media reference stride");
_Static_assert(sizeof(MarmotMediaAttachmentOutcome) == 104, "media outcome stride");
_Static_assert(MARMOT_MEDIA_ATTACHMENT_OUTCOME_ACCEPTED == 0, "accepted tag");
_Static_assert(MARMOT_MEDIA_ATTACHMENT_OUTCOME_REJECTED == 1, "rejected tag");
_Static_assert(offsetof(MarmotMediaAttachmentOutcome, ACCEPTED.attachment_index) == 8, "accepted index");
_Static_assert(offsetof(MarmotMediaAttachmentOutcome, ACCEPTED.reference) == 16, "accepted reference");
_Static_assert(offsetof(MarmotMediaAttachmentOutcome, REJECTED.attachment_index) == 8, "rejected index");
_Static_assert(offsetof(MarmotMediaAttachmentOutcome, REJECTED.rejection.kind) == 16, "rejection kind");
_Static_assert(offsetof(MarmotMediaAttachmentOutcome, REJECTED.rejection.detail) == 24, "rejection detail");
_Static_assert(sizeof(MarmotTimelineMessageRecord) == 288, "timeline stride");
_Static_assert(offsetof(MarmotTimelineMessageRecord, media) == 200, "timeline media");

int main(void) { return 0; }
