//! Remote image search for the group-photo and profile-picture pickers'
//! "search the web" badges. Openverse (<https://openverse.org>) indexes
//! openly-licensed images and its search API needs no account or key, which
//! fits a picker that has no per-user credential to spend on a provider.
//!
//! A hit's `full_url` is what gets downloaded and re-uploaded through the
//! existing Blossom path once picked (`wiring/image_search.rs`); the
//! thumbnail is fetched separately, by the generic `fetch_picture_pixels`
//! avatar pipeline, since it can fail independently of the search itself.

use anyhow::{Result, anyhow};
use serde::Deserialize;

const SEARCH_ENDPOINT: &str = "https://api.openverse.org/v1/images/";
// Openverse caps `page_size` at 20 for unauthenticated requests (this app has
// no API key to attach, by design — see the module doc).
const RESULT_LIMIT: u32 = 20;

// Named `RemoteImageHit` rather than `ImageSearchHit` to avoid shadowing the
// Slint-generated `ImageSearchHit` row type (`ui/tokens.slint`) that the
// wiring layer builds these into.
pub(crate) struct RemoteImageHit {
    pub(crate) thumbnail_url: String,
    pub(crate) full_url: String,
    pub(crate) title: String,
}

#[derive(Deserialize)]
struct OpenverseResponse {
    #[serde(default)]
    results: Vec<OpenverseResult>,
}

#[derive(Deserialize)]
struct OpenverseResult {
    #[serde(default)]
    title: String,
    url: String,
    thumbnail: String,
}

pub(crate) async fn search_images(query: &str) -> Result<Vec<RemoteImageHit>> {
    let mut url = reqwest::Url::parse(SEARCH_ENDPOINT).map_err(|e| anyhow!("bad endpoint: {e}"))?;
    url.query_pairs_mut()
        .append_pair("q", query)
        .append_pair("page_size", &RESULT_LIMIT.to_string());

    let response = reqwest::get(url)
        .await
        .map_err(|e| anyhow!("search request failed: {e}"))?;
    let status = response.status();
    if !status.is_success() {
        return Err(anyhow!("search failed: HTTP {status}"));
    }
    let body = response
        .text()
        .await
        .map_err(|e| anyhow!("reading response failed: {e}"))?;
    let parsed: OpenverseResponse =
        serde_json::from_str(&body).map_err(|e| anyhow!("parsing response failed: {e}"))?;

    Ok(parsed
        .results
        .into_iter()
        .filter(|r| !r.url.is_empty() && !r.thumbnail.is_empty())
        .map(|r| RemoteImageHit {
            thumbnail_url: r.thumbnail,
            full_url: r.url,
            title: r.title,
        })
        .collect())
}
