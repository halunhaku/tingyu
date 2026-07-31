use std::path::Path;

use ferrous_opencc::{config::BuiltinConfig, OpenCC};
use reqwest::{Client, StatusCode};
use serde::Deserialize;

use crate::metadata;

pub const ENRICHMENT_VERSION: u32 = 4;
const MAX_COVER_SIZE: usize = 10 * 1024 * 1024;

#[derive(Debug, Default)]
pub struct ScrapedMetadata {
    pub plain_lyrics: Option<String>,
    pub synced_lyrics: Option<String>,
    pub cover_file: Option<String>,
    pub complete: bool,
}

pub async fn scrape(
    client: &Client,
    title: &str,
    artist: &str,
    album: &str,
    duration: f64,
    scrape_cover: bool,
    cover_dir: &Path,
) -> ScrapedMetadata {
    let lyrics = fetch_lyrics(client, title, artist, album, duration);
    let cover = async {
        if scrape_cover {
            fetch_cover(client, artist, album, cover_dir).await
        } else {
            Ok(None)
        }
    };
    let (lyrics, cover) = tokio::join!(lyrics, cover);

    if let Err(error) = &lyrics {
        log::warn!("lyrics scraping failed for {artist} - {title}: {error}");
    }
    if let Err(error) = &cover {
        log::warn!("cover scraping failed for {artist} - {album}: {error}");
    }

    let (plain_lyrics, synced_lyrics) = lyrics
        .as_ref()
        .ok()
        .and_then(|value| value.as_ref())
        .map(|value| (value.plain_lyrics.clone(), value.synced_lyrics.clone()))
        .unwrap_or_default();

    ScrapedMetadata {
        plain_lyrics,
        synced_lyrics,
        cover_file: cover.as_ref().ok().and_then(|value| value.clone()),
        complete: lyrics.is_ok() && cover.is_ok(),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LyricsResponse {
    plain_lyrics: Option<String>,
    synced_lyrics: Option<String>,
    #[serde(default)]
    instrumental: bool,
}

async fn fetch_lyrics(
    client: &Client,
    title: &str,
    artist: &str,
    album: &str,
    duration: f64,
) -> Result<Option<LyricsResponse>, String> {
    if title.trim().is_empty() || is_unknown(artist) {
        return Ok(None);
    }
    let mut query = vec![
        ("track_name", title.trim().to_string()),
        ("artist_name", artist.trim().to_string()),
    ];
    if !album.trim().is_empty() && !is_unknown(album) {
        query.push(("album_name", album.trim().to_string()));
    }
    if duration.is_finite() && duration > 0.0 {
        query.push(("duration", duration.round().to_string()));
    }

    let response = client
        .get("https://lrclib.net/api/get")
        .query(&query)
        .send()
        .await
        .map_err(|error| format!("LRCLIB 请求失败：{error}"))?;
    if response.status() == StatusCode::NOT_FOUND {
        return Ok(None);
    }
    if !response.status().is_success() {
        return Err(format!("LRCLIB 返回 {}", response.status()));
    }
    let body = response
        .text()
        .await
        .map_err(|error| format!("无法读取 LRCLIB 响应：{error}"))?;
    let mut lyrics: LyricsResponse =
        serde_json::from_str(&body).map_err(|error| format!("LRCLIB 响应无效：{error}"))?;
    if lyrics.instrumental {
        lyrics.plain_lyrics = None;
        lyrics.synced_lyrics = None;
    }
    lyrics.plain_lyrics = simplify_chinese(clean(lyrics.plain_lyrics));
    lyrics.synced_lyrics = simplify_chinese(clean(lyrics.synced_lyrics));
    Ok(Some(lyrics))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ItunesSearchResponse {
    results: Vec<ItunesAlbum>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ItunesAlbum {
    artist_name: String,
    collection_name: String,
    artwork_url_100: Option<String>,
}

async fn fetch_cover(
    client: &Client,
    artist: &str,
    album: &str,
    cover_dir: &Path,
) -> Result<Option<String>, String> {
    if is_unknown(artist) || is_unknown(album) || album.trim().is_empty() {
        return Ok(None);
    }
    let term = format!("{} {}", artist.trim(), album.trim());
    let response = client
        .get("https://itunes.apple.com/search")
        .query(&[
            ("term", term.as_str()),
            ("media", "music"),
            ("entity", "album"),
            ("limit", "8"),
        ])
        .send()
        .await
        .map_err(|error| format!("iTunes Search 请求失败：{error}"))?;
    if !response.status().is_success() {
        return Err(format!("iTunes Search 返回 {}", response.status()));
    }
    let body = response
        .text()
        .await
        .map_err(|error| format!("无法读取 iTunes Search 响应：{error}"))?;
    let search: ItunesSearchResponse =
        serde_json::from_str(&body).map_err(|error| format!("iTunes Search 响应无效：{error}"))?;
    let Some(result) = best_album_match(&search.results, artist, album) else {
        return Ok(None);
    };
    let Some(url) = result.artwork_url_100.as_deref() else {
        return Ok(None);
    };
    let large_url = url.replace("100x100bb", "1200x1200bb");
    let image = client
        .get(large_url)
        .send()
        .await
        .map_err(|error| format!("封面下载失败：{error}"))?;
    if !image.status().is_success() {
        return Err(format!("封面服务器返回 {}", image.status()));
    }
    if image
        .content_length()
        .is_some_and(|size| size > MAX_COVER_SIZE as u64)
    {
        return Err("封面文件超过 10 MB".into());
    }
    let extension = image
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(|value| {
            if value.contains("png") {
                "png"
            } else if value.contains("webp") {
                "webp"
            } else {
                "jpg"
            }
        })
        .unwrap_or("jpg");
    let bytes = image
        .bytes()
        .await
        .map_err(|error| format!("无法读取封面：{error}"))?;
    if bytes.len() > MAX_COVER_SIZE {
        return Err("封面文件超过 10 MB".into());
    }
    let cache_key = format!("scraped:{}:{}", normalize(artist), normalize(album));
    metadata::save_cover_bytes(cover_dir, &cache_key, extension, &bytes).map(Some)
}

fn best_album_match<'a>(
    results: &'a [ItunesAlbum],
    requested_artist: &str,
    requested_album: &str,
) -> Option<&'a ItunesAlbum> {
    let artist = normalize(requested_artist);
    let album = normalize(requested_album);
    results
        .iter()
        .filter_map(|candidate| {
            let candidate_artist = normalize(&candidate.artist_name);
            let candidate_album = normalize(&candidate.collection_name);
            let artist_score = similarity_score(&artist, &candidate_artist);
            let album_score = similarity_score(&album, &candidate_album);
            (artist_score > 0 && album_score > 0)
                .then_some((artist_score * 2 + album_score * 3, candidate))
        })
        .max_by_key(|(score, _)| *score)
        .map(|(_, candidate)| candidate)
        // iTunes often transliterates Chinese artist names and returns traditional
        // album titles. The combined search query is still relevant, so use its
        // first artwork result when script conversion prevents an exact match.
        .or_else(|| {
            results
                .iter()
                .find(|candidate| candidate.artwork_url_100.is_some())
        })
}

fn similarity_score(expected: &str, candidate: &str) -> u8 {
    if expected == candidate {
        3
    } else if candidate.contains(expected) || expected.contains(candidate) {
        2
    } else {
        0
    }
}

fn normalize(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

fn is_unknown(value: &str) -> bool {
    let normalized = normalize(value);
    normalized.is_empty()
        || normalized == "未知艺术家"
        || normalized == "未知专辑"
        || normalized == "webdav曲库"
        || normalized == "unknownartist"
        || normalized == "unknownalbum"
}

thread_local! {
    static TRADITIONAL_TO_SIMPLIFIED: Option<OpenCC> =
        OpenCC::from_config(BuiltinConfig::Tw2sp).ok();
}

pub fn simplify_chinese(value: Option<String>) -> Option<String> {
    value.map(|text| {
        TRADITIONAL_TO_SIMPLIFIED.with(|converter| {
            converter
                .as_ref()
                .map_or(text.clone(), |converter| converter.convert(&text))
        })
    })
}

fn clean(value: Option<String>) -> Option<String> {
    value
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_chinese_lyrics_without_changing_foreign_text() {
        let lyrics = simplify_chinese(Some(
            "故事的小黃花，從出生那年就飄著\nRe So So Si Do Si La".into(),
        ));
        assert_eq!(
            lyrics.as_deref(),
            Some("故事的小黄花，从出生那年就飘着\nRe So So Si Do Si La")
        );
    }

    #[test]
    fn normalizes_punctuation_and_case() {
        assert_eq!(normalize("La femme d’argent"), "lafemmedargent");
        assert_eq!(normalize("ONCLE JAZZ (Deluxe)"), "onclejazzdeluxe");
    }

    #[test]
    fn chooses_matching_album_over_first_result() {
        let results = vec![
            ItunesAlbum {
                artist_name: "Someone Else".into(),
                collection_name: "Moon Safari".into(),
                artwork_url_100: None,
            },
            ItunesAlbum {
                artist_name: "Air".into(),
                collection_name: "Moon Safari (Remastered)".into(),
                artwork_url_100: Some("cover".into()),
            },
        ];
        let selected = best_album_match(&results, "Air", "Moon Safari").unwrap();
        assert_eq!(selected.artwork_url_100.as_deref(), Some("cover"));
    }

    #[test]
    fn falls_back_when_itunes_transliterates_chinese_metadata() {
        let results = vec![ItunesAlbum {
            artist_name: "Jay Chou".into(),
            collection_name: "葉惠美".into(),
            artwork_url_100: Some("cover".into()),
        }];
        let selected = best_album_match(&results, "周杰伦", "叶惠美").unwrap();
        assert_eq!(selected.artwork_url_100.as_deref(), Some("cover"));
    }
}
