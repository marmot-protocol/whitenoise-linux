// The messaging half of `impl Backend`: send/reply/edit/delete/react plus the
// media upload/download ops. Split out of `backend.rs` (same child-module
// pattern as `groups.rs`) to keep that file under the 2000-line pre-commit
// cap; see the module declarations at the bottom of `backend.rs`.

use super::*;

const REACTION_MESSAGE_KIND: u64 = 7;

fn first_event_ref(tags: &[Vec<String>]) -> Option<&str> {
    tags.iter()
        .find(|tag| tag.len() >= 2 && tag[0] == "e")
        .map(|tag| tag[1].as_str())
}

fn own_reaction_event_id_for_emoji(
    messages: &[AppMessageRecord],
    sender: &str,
    target_message_id: &str,
    emoji: &str,
) -> Option<String> {
    let emoji = emoji.trim();
    if emoji.is_empty() {
        return None;
    }
    messages
        .iter()
        .rev()
        .find(|message| {
            message.kind == REACTION_MESSAGE_KIND
                && message.sender.eq_ignore_ascii_case(sender)
                && first_event_ref(&message.tags)
                    .is_some_and(|target| target.eq_ignore_ascii_case(target_message_id))
                && message.plaintext.trim() == emoji
                && !message.message_id_hex.is_empty()
        })
        .map(|message| message.message_id_hex.clone())
}

impl Backend {
    /// Synchronous send, kept for the staged harness bins (`dm-ctl` calls it
    /// from its blocking command loop); the UI always goes through
    /// [`Backend::send_text_async`], hence the dead-code allow in the main
    /// binary.
    #[allow(dead_code)]
    pub fn send_text(&self, group_hex: &str, text: &str) -> Result<SendSummary> {
        let group_id = group_id_from_hex(group_hex)?;
        let label = self.active_label();
        let runtime = self.runtime.clone();
        let payload = text.as_bytes().to_vec();
        self.tokio.block_on(async move {
            runtime
                .send_message(&label, &group_id, payload)
                .await
                .map_err(|e| anyhow!("send_message: {e}"))
        })
    }

    /// Synchronous reaction, kept for the staged harness bins like
    /// [`Backend::send_text`]; the UI goes through the async react path.
    #[allow(dead_code)]
    pub fn react(&self, group_hex: &str, message_id_hex: &str, emoji: &str) -> Result<SendSummary> {
        let group_id = group_id_from_hex(group_hex)?;
        let label = self.active_label();
        let runtime = self.runtime.clone();
        let target = message_id_hex.to_string();
        let emoji = emoji.to_string();
        self.tokio.block_on(async move {
            runtime
                .react_to_message(&label, &group_id, &target, &emoji)
                .await
                .map_err(|e| anyhow!("react_to_message: {e}"))
        })
    }

    /// Non-blocking send: dispatches the network round-trip onto the tokio
    /// runtime and returns immediately. The callback fires (on a tokio worker
    /// thread) when the send resolves. The UI is responsible for hopping back
    /// onto the Slint event loop in the callback.
    ///
    /// This is the engine behind optimistic-rendering — the UI inserts a
    /// pending bubble first, then calls this, then reconciles on done.
    pub fn send_text_async<F>(&self, group_hex: &str, text: &str, on_done: F)
    where
        F: FnOnce(Result<SendSummary>) + Send + 'static,
    {
        let group_id = match group_id_from_hex(group_hex) {
            Ok(g) => g,
            Err(e) => {
                on_done(Err(e));
                return;
            }
        };
        let label = self.active_label();
        let runtime = self.runtime.clone();
        let payload = text.as_bytes().to_vec();
        self.tokio.spawn(async move {
            let res = runtime
                .send_message(&label, &group_id, payload)
                .await
                .map_err(|e| anyhow!("send_message: {e}"));
            on_done(res);
        });
    }

    /// Non-blocking media upload + send. Encrypts `plaintext` with the
    /// group's MLS exporter secret, uploads the encrypted blob to Blossom,
    /// and publishes a kind-9 chat carrying the NIP-92 `imeta` tag in one
    /// flow. `on_done` fires on the tokio runtime once the round-trip
    /// resolves.
    pub fn upload_media_async<F>(
        &self,
        group_hex: &str,
        file_name: String,
        media_type: String,
        plaintext: Vec<u8>,
        caption: Option<String>,
        on_done: F,
    ) where
        F: FnOnce(Result<MediaUploadResult>) + Send + 'static,
    {
        let group_id = match group_id_from_hex(group_hex) {
            Ok(g) => g,
            Err(e) => {
                on_done(Err(e));
                return;
            }
        };
        let label = self.active_label();
        let runtime = self.runtime.clone();
        let request = MediaUploadRequest {
            attachments: vec![MediaUploadAttachmentRequest {
                file_name,
                media_type,
                plaintext,
                dim: None,
                thumbhash: None,
            }],
            caption,
            send: true,
            blossom_server: None,
        };
        self.tokio.spawn(async move {
            on_done(upload_media_with_heal(runtime, label, group_id, request).await);
        });
    }

    /// Non-blocking album upload + send: all images go out as **one** kind-9
    /// message carrying one `imeta` tag per image (so the UI renders them as a
    /// single grid bubble). Each item is `(file_name, media_type, plaintext,
    /// dim)`, where `dim` is `"WxH"` so receivers can lay out the grid without
    /// decoding. Shares the same self-heal-and-retry as [`upload_media_async`].
    pub fn upload_album_async<F>(
        &self,
        group_hex: &str,
        items: Vec<(String, String, Vec<u8>, Option<String>)>,
        on_done: F,
    ) where
        F: FnOnce(Result<MediaUploadResult>) + Send + 'static,
    {
        let group_id = match group_id_from_hex(group_hex) {
            Ok(g) => g,
            Err(e) => {
                on_done(Err(e));
                return;
            }
        };
        let label = self.active_label();
        let runtime = self.runtime.clone();
        let request = MediaUploadRequest {
            attachments: items
                .into_iter()
                .map(
                    |(file_name, media_type, plaintext, dim)| MediaUploadAttachmentRequest {
                        file_name,
                        media_type,
                        plaintext,
                        dim,
                        thumbhash: None,
                    },
                )
                .collect(),
            caption: None,
            send: true,
            blossom_server: None,
        };
        self.tokio.spawn(async move {
            on_done(upload_media_with_heal(runtime, label, group_id, request).await);
        });
    }

    /// Non-blocking media download + decrypt. Fetches the encrypted blob
    /// from Blossom, verifies the ciphertext hash, decrypts with the
    /// group's exporter secret, and hands back the plaintext bytes + the
    /// resolved filename/mime/size.
    pub fn download_media_async<F>(
        &self,
        group_hex: &str,
        reference: MediaAttachmentReference,
        on_done: F,
    ) where
        F: FnOnce(Result<MediaDownloadResult>) + Send + 'static,
    {
        let group_id = match group_id_from_hex(group_hex) {
            Ok(g) => g,
            Err(e) => {
                on_done(Err(e));
                return;
            }
        };
        let label = self.active_label();
        let runtime = self.runtime.clone();
        self.tokio.spawn(async move {
            let res = download_media_with_redirect_retry(runtime, label, group_id, reference).await;
            on_done(res);
        });
    }

    /// Non-blocking reply send. Same shape as [`send_text_async`] — the
    /// difference is the wire event carries `e` + `q` tags pointing at
    /// `parent_message_id_hex`, encoded by `AppMessageIntent::Reply`. The
    /// optimistic-render reconciliation in the UI layer treats it identically
    /// to a normal send (it's still a kind-9 chat).
    pub fn reply_text_async<F>(
        &self,
        group_hex: &str,
        parent_message_id_hex: &str,
        text: &str,
        on_done: F,
    ) where
        F: FnOnce(Result<SendSummary>) + Send + 'static,
    {
        let group_id = match group_id_from_hex(group_hex) {
            Ok(g) => g,
            Err(e) => {
                on_done(Err(e));
                return;
            }
        };
        let label = self.active_label();
        let runtime = self.runtime.clone();
        let parent = parent_message_id_hex.to_string();
        let text = text.to_string();
        self.tokio.spawn(async move {
            let res = runtime
                .reply_to_message(&label, &group_id, &parent, &text)
                .await
                .map_err(|e| anyhow!("reply_to_message: {e}"));
            on_done(res);
        });
    }

    /// Non-blocking variant of [`react`]. See [`send_text_async`] for the
    /// rationale — same shape, optimistic-render reconciliation lives in the
    /// UI layer.
    pub fn react_async<F>(&self, group_hex: &str, message_id_hex: &str, emoji: &str, on_done: F)
    where
        F: FnOnce(Result<SendSummary>) + Send + 'static,
    {
        let group_id = match group_id_from_hex(group_hex) {
            Ok(g) => g,
            Err(e) => {
                on_done(Err(e));
                return;
            }
        };
        let label = self.active_label();
        let runtime = self.runtime.clone();
        let target = message_id_hex.to_string();
        let emoji = emoji.to_string();
        self.tokio.spawn(async move {
            let res = runtime
                .react_to_message(&label, &group_id, &target, &emoji)
                .await
                .map_err(|e| anyhow!("react_to_message: {e}"));
            on_done(res);
        });
    }

    /// Publish a kind-1009 edit of `message_id_hex` with replacement text
    /// `content`. Same optimistic-reconciliation shape as [`react_async`] — the
    /// UI overlay rewrites the bubble immediately and the ack/echo reconciles.
    pub fn edit_message_async<F>(
        &self,
        group_hex: &str,
        message_id_hex: &str,
        content: &str,
        on_done: F,
    ) where
        F: FnOnce(Result<SendSummary>) + Send + 'static,
    {
        let group_id = match group_id_from_hex(group_hex) {
            Ok(g) => g,
            Err(e) => {
                on_done(Err(e));
                return;
            }
        };
        let label = self.active_label();
        let runtime = self.runtime.clone();
        let target = message_id_hex.to_string();
        let content = content.to_string();
        self.tokio.spawn(async move {
            let res = runtime
                .edit_message(&label, &group_id, &target, &content)
                .await
                .map_err(|e| anyhow!("edit_message: {e}"));
            on_done(res);
        });
    }

    /// Retract `message_id_hex` for everyone: publish a kind-5 delete event
    /// referencing the target. Marmot enforces on read that a delete is only
    /// honored when its authenticated author matches the target's author, so
    /// this only meaningfully retracts the user's own messages. Same optimistic-
    /// reconciliation shape as [`edit_message_async`].
    pub fn delete_message_async<F>(&self, group_hex: &str, message_id_hex: &str, on_done: F)
    where
        F: FnOnce(Result<SendSummary>) + Send + 'static,
    {
        let group_id = match group_id_from_hex(group_hex) {
            Ok(g) => g,
            Err(e) => {
                on_done(Err(e));
                return;
            }
        };
        let label = self.active_label();
        let runtime = self.runtime.clone();
        let target = message_id_hex.to_string();
        self.tokio.spawn(async move {
            let res = runtime
                .delete_message(&label, &group_id, &target)
                .await
                .map_err(|e| anyhow!("delete_message: {e}"));
            on_done(res);
        });
    }

    /// Non-blocking variant of [`unreact`].
    pub fn unreact_async<F>(&self, group_hex: &str, message_id_hex: &str, emoji: &str, on_done: F)
    where
        F: FnOnce(Result<SendSummary>) + Send + 'static,
    {
        let group_id = match group_id_from_hex(group_hex) {
            Ok(g) => g,
            Err(e) => {
                on_done(Err(e));
                return;
            }
        };
        let label = self.active_label();
        let sender = self.active_id();
        let app = self.app.clone();
        let runtime = self.runtime.clone();
        let group_hex = group_hex.to_string();
        let target = message_id_hex.to_string();
        let emoji = emoji.to_string();
        self.tokio.spawn(async move {
            let res = async {
                let messages = app
                    .messages_with_query(
                        &label,
                        AppMessageQuery {
                            group_id_hex: Some(group_hex),
                            limit: None,
                        },
                    )
                    .map_err(|e| anyhow!("messages_with_query: {e}"))?;
                let reaction_id =
                    own_reaction_event_id_for_emoji(&messages, &sender, &target, &emoji)
                        .ok_or_else(|| anyhow!("reaction not found for tapped emoji"))?;
                runtime
                    .delete_message(&label, &group_id, &reaction_id)
                    .await
                    .map_err(|e| anyhow!("delete reaction: {e}"))
            }
            .await;
            on_done(res);
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reaction(
        id: &str,
        sender: &str,
        target: &str,
        emoji: &str,
        recorded_at: u64,
    ) -> AppMessageRecord {
        AppMessageRecord {
            message_id_hex: id.to_string(),
            direction: "in".to_string(),
            group_id_hex: "group".to_string(),
            sender: sender.to_string(),
            plaintext: emoji.to_string(),
            kind: 7,
            tags: vec![vec!["e".to_string(), target.to_string()]],
            source_epoch: None,
            recorded_at,
            received_at: recorded_at,
            insert_order: recorded_at as i64,
        }
    }

    #[test]
    fn own_reaction_lookup_filters_by_tapped_emoji() {
        let messages = vec![
            reaction("own-heart", "me", "target", "❤️", 1),
            reaction("own-fire", "me", "target", "🔥", 2),
            reaction("other-fire", "other", "target", "🔥", 3),
            reaction("own-heart-newer", "me", "target", "❤️", 4),
        ];

        assert_eq!(
            own_reaction_event_id_for_emoji(&messages, "me", "target", "🔥"),
            Some("own-fire".to_string())
        );
    }

    #[test]
    fn own_reaction_lookup_uses_latest_matching_emoji() {
        let messages = vec![
            reaction("old-heart", "me", "target", "❤️", 1),
            reaction("new-heart", "me", "target", "❤️", 2),
        ];

        assert_eq!(
            own_reaction_event_id_for_emoji(&messages, "me", "target", "❤️"),
            Some("new-heart".to_string())
        );
    }
}
