// Public (unencrypted) Blossom uploads.
//
// marmot-app already ships an *encrypted* media path (MIP-04) for chat
// attachments — those blobs are sealed so only group members can read them.
// A profile picture is the opposite: it must be publicly fetchable by anyone
// who opens your kind-0 metadata. So this is a separate, deliberately simple
// path that uploads the raw image bytes and returns the public URL we then
// stuff into the `picture` field of the profile.
//
// Protocol is BUD-01/BUD-02 (https://github.com/hzrd149/blossom): PUT /upload
// with the raw body, an `Authorization: Nostr <base64(event)>` header carrying
// a signed kind-24242 event, and an `X-SHA-256` hint. The server replies with a
// blob descriptor `{ url, sha256, ... }`.

use anyhow::{Result, anyhow};
use nostr::base64::Engine as _;
use nostr::base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64_URL_SAFE_NO_PAD;
use nostr::{EventBuilder, JsonUtil, Kind, Tag, Timestamp as NostrTimestamp};
use sha2::{Digest, Sha256};

/// Default Blossom server. Same one marmot uses for encrypted media.
pub const DEFAULT_BLOSSOM_SERVER: &str = "https://blossom.primal.net";

/// Auth events are short-lived; ten minutes is plenty for one PUT.
const UPLOAD_AUTH_TTL_SECS: u64 = 10 * 60;

/// Upload `bytes` to `server` as a public blob and return its URL.
///
/// `content_type` is the real MIME type (e.g. `image/png`) — unlike the
/// encrypted path which always sends `application/octet-stream`, here we want
/// the server to serve the blob back with a sensible type so browsers and
/// other Nostr clients render the avatar.
pub async fn upload_public_blob(
    server: &str,
    bytes: Vec<u8>,
    content_type: &str,
    keys: &nostr::Keys,
) -> Result<String> {
    if bytes.is_empty() {
        return Err(anyhow!("image is empty"));
    }
    let hash_hex = hex::encode(Sha256::digest(&bytes));
    let (upload_url, host) = upload_endpoint(server)?;
    let authorization = authorization_header(keys, &host, &hash_hex)?;

    let response = reqwest::Client::new()
        .put(&upload_url)
        .header(reqwest::header::AUTHORIZATION, authorization)
        .header(reqwest::header::CONTENT_TYPE, content_type)
        .header("X-SHA-256", &hash_hex)
        .body(bytes)
        .send()
        .await
        .map_err(|e| anyhow!("upload request failed: {e}"))?;

    let status = response.status();
    if !status.is_success() {
        let detail = response.text().await.unwrap_or_default();
        let detail = detail.trim();
        return Err(if detail.is_empty() {
            anyhow!("upload returned HTTP {}", status.as_u16())
        } else {
            anyhow!("upload returned HTTP {}: {detail}", status.as_u16())
        });
    }

    // The descriptor's `url` is authoritative (servers may use a CDN host or a
    // different extension). Fall back to a conventional `{server}/{hash}` if the
    // body is missing or malformed.
    let descriptor = response.json::<serde_json::Value>().await.ok();
    if let Some(url) = descriptor
        .as_ref()
        .and_then(|d| d.get("url"))
        .and_then(|u| u.as_str())
        .map(str::trim)
        .filter(|u| !u.is_empty())
    {
        return Ok(url.to_owned());
    }
    Ok(blob_url(server, &hash_hex))
}

/// Split a server base URL into the `/upload` endpoint and its bare host (the
/// host goes into the auth event's `server` tag). Kept dependency-free — no
/// `url` crate — because the inputs are simple `https://host[/]` strings.
fn upload_endpoint(server: &str) -> Result<(String, String)> {
    let trimmed = server.trim();
    let scheme_end = trimmed
        .find("://")
        .ok_or_else(|| anyhow!("Blossom server URL must be http(s)://…"))?;
    let scheme = &trimmed[..scheme_end];
    if scheme != "http" && scheme != "https" {
        return Err(anyhow!("Blossom server URL must be http or https"));
    }
    let after = &trimmed[scheme_end + 3..];
    let host = after.split('/').next().unwrap_or("").to_ascii_lowercase();
    if host.is_empty() {
        return Err(anyhow!("Blossom server URL is missing a host"));
    }
    let base = trimmed.trim_end_matches('/');
    Ok((format!("{base}/upload"), host))
}

/// Conventional fallback blob URL when the server omits one in its descriptor.
fn blob_url(server: &str, hash_hex: &str) -> String {
    format!("{}/{}", server.trim().trim_end_matches('/'), hash_hex)
}

fn authorization_header(keys: &nostr::Keys, host: &str, hash_hex: &str) -> Result<String> {
    let now = unix_now_seconds();
    let expiration = now + UPLOAD_AUTH_TTL_SECS;
    let tags = [
        Tag::parse(["t", "upload"]),
        Tag::parse(["expiration", &expiration.to_string()]),
        Tag::parse(["x", hash_hex]),
        Tag::parse(["server", host]),
    ]
    .into_iter()
    .collect::<Result<Vec<_>, _>>()
    .map_err(|e| anyhow!("failed to build Blossom auth tag: {e}"))?;
    let event = EventBuilder::new(Kind::Custom(24242), "Upload Blob")
        .tags(tags)
        .custom_created_at(NostrTimestamp::from(now))
        .sign_with_keys(keys)
        .map_err(|e| anyhow!("failed to sign Blossom auth: {e}"))?;
    Ok(format!(
        "Nostr {}",
        BASE64_URL_SAFE_NO_PAD.encode(event.as_json())
    ))
}

fn unix_now_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
