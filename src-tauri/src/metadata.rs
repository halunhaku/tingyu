use std::{io::Cursor, path::Path};

use futures_util::StreamExt;
use lofty::{
    config::ParseOptions,
    file::{AudioFile, FileType, TaggedFileExt},
    picture::PictureType,
    probe::Probe,
    tag::{Accessor, ItemKey},
};
use reqwest::{header, Client, Url};
use sha2::{Digest, Sha256};

const INITIAL_PREFIX: usize = 256 * 1024;
const MAX_METADATA_PREFIX: usize = 12 * 1024 * 1024;
const MAX_COVER_SIZE: usize = 10 * 1024 * 1024;

#[derive(Debug, Default)]
pub struct ExtractedMetadata {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub year: Option<u32>,
    pub duration: f64,
    pub cover_file: Option<String>,
    pub plain_lyrics: Option<String>,
}

pub async fn extract(
    client: &Client,
    url: &Url,
    username: &str,
    password: &str,
    filename: &str,
    cache_key: &str,
    cover_dir: &Path,
) -> Result<ExtractedMetadata, String> {
    let extension = filename
        .rsplit('.')
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let file_type = match extension.as_str() {
        "mp3" => FileType::Mpeg,
        "flac" => FileType::Flac,
        _ => return Ok(ExtractedMetadata::default()),
    };

    let mut bytes = fetch_prefix(client, url, username, password, INITIAL_PREFIX).await?;
    loop {
        let required = match file_type {
            FileType::Mpeg => id3_prefix_length(&bytes),
            FileType::Flac => flac_prefix_length(&bytes),
            _ => None,
        }
        .unwrap_or(bytes.len())
        .clamp(bytes.len(), MAX_METADATA_PREFIX);
        if required <= bytes.len() || bytes.len() >= MAX_METADATA_PREFIX {
            break;
        }
        let expanded = fetch_prefix(client, url, username, password, required).await?;
        if expanded.len() <= bytes.len() {
            break;
        }
        bytes = expanded;
    }

    let duration = if file_type == FileType::Flac {
        flac_duration(&bytes).unwrap_or(0.0)
    } else {
        0.0
    };
    let options = ParseOptions::new()
        .read_properties(false)
        .read_cover_art(true);
    let tagged = match Probe::with_file_type(Cursor::new(bytes), file_type)
        .options(options)
        .read()
    {
        Ok(tagged) => tagged,
        Err(error) => {
            log::warn!("metadata parse failed for {filename}: {error}");
            return Ok(ExtractedMetadata {
                duration,
                ..ExtractedMetadata::default()
            });
        }
    };
    let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) else {
        return Ok(ExtractedMetadata {
            duration,
            ..ExtractedMetadata::default()
        });
    };

    let cover_file = tag
        .pictures()
        .iter()
        .find(|picture| picture.pic_type() == PictureType::CoverFront)
        .or_else(|| tag.pictures().first())
        .filter(|picture| picture.data().len() <= MAX_COVER_SIZE)
        .and_then(|picture| {
            let extension = picture
                .mime_type()
                .and_then(|mime| mime.ext())
                .unwrap_or("jpg");
            save_cover_bytes(cover_dir, cache_key, extension, picture.data()).ok()
        });

    Ok(ExtractedMetadata {
        title: clean(tag.title().map(|value| value.into_owned())),
        artist: clean(tag.artist().map(|value| value.into_owned())),
        album: clean(tag.album().map(|value| value.into_owned())),
        year: tag
            .date()
            .map(|date| u32::from(date.year))
            .filter(|year| *year > 0),
        duration,
        cover_file,
        plain_lyrics: clean(
            tag.get_string(ItemKey::UnsyncLyrics)
                .or_else(|| tag.get_string(ItemKey::Lyrics))
                .map(str::to_string),
        ),
    })
}

pub fn extract_local(
    path: &Path,
    cache_key: &str,
    cover_dir: &Path,
) -> Result<ExtractedMetadata, String> {
    let options = ParseOptions::new()
        .read_properties(true)
        .read_cover_art(true);
    let tagged = Probe::open(path)
        .map_err(|error| format!("无法打开本地音频：{error}"))?
        .options(options)
        .read()
        .map_err(|error| format!("无法读取本地音频标签：{error}"))?;
    let duration = tagged.properties().duration().as_secs_f64();
    let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) else {
        return Ok(ExtractedMetadata {
            duration,
            ..ExtractedMetadata::default()
        });
    };
    let cover_file = tag
        .pictures()
        .iter()
        .find(|picture| picture.pic_type() == PictureType::CoverFront)
        .or_else(|| tag.pictures().first())
        .filter(|picture| picture.data().len() <= MAX_COVER_SIZE)
        .and_then(|picture| {
            let extension = picture
                .mime_type()
                .and_then(|mime| mime.ext())
                .unwrap_or("jpg");
            save_cover_bytes(cover_dir, cache_key, extension, picture.data()).ok()
        });
    Ok(ExtractedMetadata {
        title: clean(tag.title().map(|value| value.into_owned())),
        artist: clean(tag.artist().map(|value| value.into_owned())),
        album: clean(tag.album().map(|value| value.into_owned())),
        year: tag
            .date()
            .map(|date| u32::from(date.year))
            .filter(|year| *year > 0),
        duration,
        cover_file,
        plain_lyrics: clean(
            tag.get_string(ItemKey::UnsyncLyrics)
                .or_else(|| tag.get_string(ItemKey::Lyrics))
                .map(str::to_string),
        ),
    })
}

async fn fetch_prefix(
    client: &Client,
    url: &Url,
    username: &str,
    password: &str,
    length: usize,
) -> Result<Vec<u8>, String> {
    let response = client
        .get(url.clone())
        .basic_auth(username, Some(password))
        .header(
            header::RANGE,
            format!("bytes=0-{}", length.saturating_sub(1)),
        )
        .send()
        .await
        .map_err(|error| format!("无法读取音频标签：{error}"))?;
    if !response.status().is_success() {
        return Err(format!("读取音频标签时服务器返回：{}", response.status()));
    }

    let mut bytes = Vec::with_capacity(length.min(INITIAL_PREFIX));
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| format!("音频标签下载中断：{error}"))?;
        let remaining = length.saturating_sub(bytes.len());
        if remaining == 0 {
            break;
        }
        bytes.extend_from_slice(&chunk[..chunk.len().min(remaining)]);
        if bytes.len() >= length {
            break;
        }
    }
    Ok(bytes)
}

fn id3_prefix_length(bytes: &[u8]) -> Option<usize> {
    if bytes.len() < 10 || &bytes[..3] != b"ID3" {
        return None;
    }
    let size = bytes[6..10].iter().fold(0usize, |value, byte| {
        (value << 7) | usize::from(byte & 0x7f)
    });
    let footer = usize::from(bytes[5] & 0x10 != 0) * 10;
    Some(10 + size + footer + 4_096)
}

fn flac_prefix_length(bytes: &[u8]) -> Option<usize> {
    if bytes.len() < 8 || &bytes[..4] != b"fLaC" {
        return None;
    }
    let mut offset = 4usize;
    loop {
        if offset + 4 > bytes.len() {
            return Some((offset + INITIAL_PREFIX).min(MAX_METADATA_PREFIX));
        }
        let is_last = bytes[offset] & 0x80 != 0;
        let block_size = (usize::from(bytes[offset + 1]) << 16)
            | (usize::from(bytes[offset + 2]) << 8)
            | usize::from(bytes[offset + 3]);
        offset = offset.saturating_add(4).saturating_add(block_size);
        if offset > MAX_METADATA_PREFIX || is_last {
            return Some(offset.saturating_add(4_096).min(MAX_METADATA_PREFIX));
        }
        if offset >= bytes.len() {
            return Some((offset + INITIAL_PREFIX).min(MAX_METADATA_PREFIX));
        }
    }
}

fn flac_duration(bytes: &[u8]) -> Option<f64> {
    if bytes.len() < 42 || &bytes[..4] != b"fLaC" || bytes[4] & 0x7f != 0 {
        return None;
    }
    let packed = u64::from_be_bytes(bytes[18..26].try_into().ok()?);
    let sample_rate = (packed >> 44) & 0x000f_ffff;
    let total_samples = packed & 0x0000_000f_ffff_ffff;
    (sample_rate > 0).then_some(total_samples as f64 / sample_rate as f64)
}

pub(crate) fn save_cover_bytes(
    directory: &Path,
    cache_key: &str,
    extension: &str,
    data: &[u8],
) -> Result<String, String> {
    std::fs::create_dir_all(directory).map_err(|error| format!("无法创建封面缓存目录：{error}"))?;
    let digest = Sha256::digest(cache_key.as_bytes());
    let filename = format!("{}.{}", hex::encode(digest), extension);
    let path = directory.join(&filename);
    if !path.exists() {
        std::fs::write(path, data).map_err(|error| format!("无法缓存专辑封面：{error}"))?;
    }
    Ok(filename)
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
    fn reads_syncsafe_id3_size() {
        let bytes = [b'I', b'D', b'3', 4, 0, 0, 0, 0, 2, 0];
        assert_eq!(id3_prefix_length(&bytes), Some(266 + 4_096));
    }

    #[test]
    fn reads_flac_stream_duration() {
        let mut bytes = vec![0; 42];
        bytes[..4].copy_from_slice(b"fLaC");
        bytes[4] = 0;
        bytes[5..8].copy_from_slice(&[0, 0, 34]);
        let packed = (44_100u64 << 44) | 88_200u64;
        bytes[18..26].copy_from_slice(&packed.to_be_bytes());
        assert_eq!(flac_duration(&bytes), Some(2.0));
    }
}
