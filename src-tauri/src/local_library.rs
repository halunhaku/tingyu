use std::{
    collections::{HashMap, VecDeque},
    path::{Path as FsPath, PathBuf},
    time::UNIX_EPOCH,
};

use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::{header, HeaderMap, Method, StatusCode},
    response::{IntoResponse, Response},
};
use futures_util::{stream, StreamExt};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;
use urlencoding::encode;

use crate::{metadata, scraper, webdav::SharedWebDavState};

const MAX_SCAN_DEPTH: usize = 8;
const MAX_SCAN_ENTRIES: usize = 5_000;
const MAX_AUTO_SCRAPES: usize = 24;
const MAX_CONCURRENT_SCRAPES: usize = 8;

#[derive(Clone, Debug)]
struct LocalTrack {
    path: String,
    name: String,
    size: u64,
    modified: u64,
    title: String,
    artist: String,
    album: String,
    year: Option<u32>,
    duration: f64,
    cover_file: Option<String>,
    plain_lyrics: Option<String>,
    synced_lyrics: Option<String>,
    enrichment_version: u32,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalEntry {
    path: String,
    name: String,
    title: String,
    artist: String,
    album: String,
    year: Option<u32>,
    duration: f64,
    size: u64,
    stream_url: String,
    artwork_url: Option<String>,
    plain_lyrics: Option<String>,
    synced_lyrics: Option<String>,
    enrichment_version: u32,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalScanResult {
    source_name: String,
    folder_path: String,
    folder_name: String,
    tracks: Vec<LocalEntry>,
}

#[derive(Debug, Serialize, Deserialize)]
struct SavedFolder {
    #[serde(default = "default_source_name")]
    name: String,
    folder: String,
}

#[derive(Debug, Deserialize)]
pub struct LocalStreamQuery {
    path: String,
}

#[tauri::command]
pub async fn local_library_scan(
    name: String,
    folder: String,
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<LocalScanResult, String> {
    scan_folder(PathBuf::from(folder), name, &state, true).await
}

#[tauri::command]
pub async fn local_library_restore(
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<Option<LocalScanResult>, String> {
    let content = match std::fs::read_to_string(&state.local_config_path) {
        Ok(content) => content,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("无法读取本地音乐源配置：{error}")),
    };
    let saved: SavedFolder =
        serde_json::from_str(&content).map_err(|error| format!("本地音乐源配置无效：{error}"))?;
    match scan_folder(PathBuf::from(saved.folder), saved.name, &state, false).await {
        Ok(result) => Ok(Some(result)),
        Err(error) => {
            log::warn!("local library restore skipped: {error}");
            Ok(None)
        }
    }
}

#[tauri::command]
pub async fn local_library_forget(
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<(), String> {
    *state.local_root.write().await = None;
    if state.local_config_path.exists() {
        std::fs::remove_file(&state.local_config_path)
            .map_err(|error| format!("无法删除本地音乐源配置：{error}"))?;
    }
    clear_cache(&state.database_path)
}

#[tauri::command]
pub async fn local_library_scrape_track(
    path: String,
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<LocalEntry, String> {
    let root = state
        .local_root
        .read()
        .await
        .clone()
        .ok_or_else(|| "请先选择本地音乐文件夹".to_string())?;
    let canonical =
        std::fs::canonicalize(&path).map_err(|error| format!("无法打开本地音频：{error}"))?;
    if !canonical.starts_with(&root) {
        return Err("音频路径超出了已选择的文件夹".into());
    }
    init_cache(&state.database_path)?;
    let mut track = load_cache(&state.database_path)?
        .remove(&path)
        .ok_or_else(|| "本地曲库中找不到这首歌".to_string())?;
    if track.enrichment_version < scraper::ENRICHMENT_VERSION {
        enrich_track(&mut track, &state).await;
        update_cached_track(&state.database_path, &track)?;
    }
    Ok(to_entry(&track, &state))
}

async fn scan_folder(
    folder: PathBuf,
    name: String,
    state: &SharedWebDavState,
    remember: bool,
) -> Result<LocalScanResult, String> {
    let root =
        std::fs::canonicalize(&folder).map_err(|error| format!("无法打开本地文件夹：{error}"))?;
    if !root.is_dir() {
        return Err("请选择一个本地文件夹".into());
    }
    let source_name = if name.trim().is_empty() {
        default_source_name()
    } else {
        name.trim().to_string()
    };
    if remember {
        save_folder(&state.local_config_path, &root, &source_name)?;
    }
    *state.local_root.write().await = Some(root.clone());

    let database_path = state.database_path.clone();
    let cover_directory = state.cover_directory.clone();
    let root_for_scan = root.clone();
    let mut tracks = tauri::async_runtime::spawn_blocking(move || {
        build_local_library(&database_path, &cover_directory, &root_for_scan)
    })
    .await
    .map_err(|error| format!("本地曲库扫描任务失败：{error}"))??;

    let candidates = tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| track.enrichment_version < scraper::ENRICHMENT_VERSION)
        .map(|(index, _)| index)
        .take(MAX_AUTO_SCRAPES)
        .collect::<Vec<_>>();
    let shared_state = state.clone();
    let enriched = stream::iter(candidates.into_iter().map(|index| {
        let shared_state = shared_state.clone();
        let mut track = tracks[index].clone();
        async move {
            enrich_track(&mut track, &shared_state).await;
            (index, track)
        }
    }))
    .buffer_unordered(MAX_CONCURRENT_SCRAPES)
    .collect::<Vec<_>>()
    .await;
    for (index, track) in enriched {
        tracks[index] = track;
    }
    save_cache(&state.database_path, &tracks)?;

    let folder_name = root
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("本地音乐")
        .to_string();
    let entries = tracks.iter().map(|track| to_entry(track, state)).collect();
    Ok(LocalScanResult {
        source_name,
        folder_path: root.to_string_lossy().into_owned(),
        folder_name,
        tracks: entries,
    })
}

fn build_local_library(
    database_path: &FsPath,
    cover_directory: &FsPath,
    root: &FsPath,
) -> Result<Vec<LocalTrack>, String> {
    init_cache(database_path)?;
    let existing = load_cache(database_path)?;
    let files = collect_audio_files(root)?;
    let mut tracks = Vec::with_capacity(files.len());
    for path in files {
        let file_metadata =
            std::fs::metadata(&path).map_err(|error| format!("无法读取本地文件信息：{error}"))?;
        let path_string = path.to_string_lossy().into_owned();
        let size = file_metadata.len();
        let modified = file_metadata
            .modified()
            .ok()
            .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
            .map_or(0, |value| value.as_nanos().min(i64::MAX as u128) as u64);
        if let Some(cached) = existing.get(&path_string) {
            if cached.size == size && cached.modified == modified {
                tracks.push(cached.clone());
                continue;
            }
        }
        let name = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("未命名音频")
            .to_string();
        let cache_key = format!("local:{path_string}:{modified}");
        let extracted =
            metadata::extract_local(&path, &cache_key, cover_directory).unwrap_or_else(|error| {
                log::warn!("local metadata extraction skipped for {name}: {error}");
                metadata::ExtractedMetadata::default()
            });
        let (fallback_artist, fallback_title) = title_from_filename(&name);
        let album = extracted.album.unwrap_or_else(|| {
            path.parent()
                .and_then(FsPath::file_name)
                .and_then(|value| value.to_str())
                .unwrap_or("本地音乐")
                .to_string()
        });
        tracks.push(LocalTrack {
            path: path_string,
            name,
            size,
            modified,
            title: extracted.title.unwrap_or(fallback_title),
            artist: extracted.artist.unwrap_or(fallback_artist),
            album,
            year: extracted.year,
            duration: extracted.duration,
            cover_file: extracted.cover_file,
            plain_lyrics: extracted.plain_lyrics,
            synced_lyrics: None,
            enrichment_version: 0,
        });
    }
    Ok(tracks)
}

async fn enrich_track(track: &mut LocalTrack, state: &SharedWebDavState) {
    track.plain_lyrics = scraper::simplify_chinese(track.plain_lyrics.take());
    track.synced_lyrics = scraper::simplify_chinese(track.synced_lyrics.take());
    let scraped = scraper::scrape(
        &state.scraper_client,
        &track.title,
        &track.artist,
        &track.album,
        track.duration,
        track.cover_file.is_none(),
        &state.cover_directory,
    )
    .await;
    if track.cover_file.is_none() {
        track.cover_file = scraped.cover_file;
    }
    if track.plain_lyrics.is_none() {
        track.plain_lyrics = scraped.plain_lyrics;
    }
    if track.synced_lyrics.is_none() {
        track.synced_lyrics = scraped.synced_lyrics;
    }
    if scraped.complete {
        track.enrichment_version = scraper::ENRICHMENT_VERSION;
    }
}

fn to_entry(track: &LocalTrack, state: &SharedWebDavState) -> LocalEntry {
    LocalEntry {
        path: track.path.clone(),
        name: track.name.clone(),
        title: track.title.clone(),
        artist: track.artist.clone(),
        album: track.album.clone(),
        year: track.year,
        duration: track.duration,
        size: track.size,
        stream_url: format!(
            "{}/local/{}?path={}",
            state.proxy_origin,
            state.proxy_token,
            encode(&track.path)
        ),
        artwork_url: track.cover_file.as_ref().map(|filename| {
            format!(
                "{}/cover/{}/{}",
                state.proxy_origin, state.proxy_token, filename
            )
        }),
        plain_lyrics: track.plain_lyrics.clone(),
        synced_lyrics: track.synced_lyrics.clone(),
        enrichment_version: track.enrichment_version,
    }
}

fn collect_audio_files(root: &FsPath) -> Result<Vec<PathBuf>, String> {
    let mut queue = VecDeque::from([(root.to_path_buf(), 0usize)]);
    let mut files = Vec::new();
    while let Some((directory, depth)) = queue.pop_front() {
        let entries = std::fs::read_dir(&directory)
            .map_err(|error| format!("无法读取本地文件夹：{error}"))?;
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_symlink() {
                continue;
            }
            if file_type.is_dir() {
                if depth < MAX_SCAN_DEPTH {
                    queue.push_back((path, depth + 1));
                }
            } else if file_type.is_file() && is_audio_file(&path) {
                files.push(path);
                if files.len() >= MAX_SCAN_ENTRIES {
                    return Err(format!("本地曲库超过 {MAX_SCAN_ENTRIES} 首，已停止扫描"));
                }
            }
        }
    }
    files.sort();
    Ok(files)
}

fn is_audio_file(path: &FsPath) -> bool {
    matches!(
        path.extension()
            .and_then(|value| value.to_str())
            .unwrap_or("")
            .to_ascii_lowercase()
            .as_str(),
        "mp3" | "flac" | "m4a" | "aac" | "wav" | "ogg" | "opus"
    )
}

fn title_from_filename(name: &str) -> (String, String) {
    let filename = name.rsplit_once('.').map_or(name, |(stem, _)| stem);
    if let Some((artist, title)) = filename.split_once(" - ") {
        (artist.trim().to_string(), title.trim().to_string())
    } else {
        ("未知艺术家".into(), filename.to_string())
    }
}

fn save_folder(path: &FsPath, root: &FsPath, name: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("无法创建本地音乐源配置目录：{error}"))?;
    }
    let content = serde_json::to_vec_pretty(&SavedFolder {
        name: name.to_string(),
        folder: root.to_string_lossy().into_owned(),
    })
    .map_err(|error| format!("无法保存本地音乐源配置：{error}"))?;
    std::fs::write(path, content).map_err(|error| format!("无法保存本地音乐源配置：{error}"))
}

fn init_cache(path: &FsPath) -> Result<(), String> {
    let connection = Connection::open(path).map_err(cache_error)?;
    connection
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS local_tracks (
                path TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                size INTEGER NOT NULL,
                modified INTEGER NOT NULL,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                album TEXT NOT NULL,
                year INTEGER,
                duration REAL NOT NULL DEFAULT 0,
                cover_file TEXT,
                plain_lyrics TEXT,
                synced_lyrics TEXT,
                enrichment_version INTEGER NOT NULL DEFAULT 0
            );",
        )
        .map_err(cache_error)
}

fn load_cache(path: &FsPath) -> Result<HashMap<String, LocalTrack>, String> {
    let connection = Connection::open(path).map_err(cache_error)?;
    let mut statement = connection
        .prepare(
            "SELECT path, name, size, modified, title, artist, album, year, duration,
                    cover_file, plain_lyrics, synced_lyrics, enrichment_version
             FROM local_tracks",
        )
        .map_err(cache_error)?;
    let rows = statement
        .query_map([], |row| {
            Ok(LocalTrack {
                path: row.get(0)?,
                name: row.get(1)?,
                size: row.get::<_, i64>(2)?.max(0) as u64,
                modified: row.get::<_, i64>(3)?.max(0) as u64,
                title: row.get(4)?,
                artist: row.get(5)?,
                album: row.get(6)?,
                year: row.get(7)?,
                duration: row.get(8)?,
                cover_file: row.get(9)?,
                plain_lyrics: row.get(10)?,
                synced_lyrics: row.get(11)?,
                enrichment_version: row.get::<_, i64>(12)?.max(0) as u32,
            })
        })
        .map_err(cache_error)?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(cache_error)
        .map(|tracks| {
            tracks
                .into_iter()
                .map(|track| (track.path.clone(), track))
                .collect()
        })
}

fn clear_cache(path: &FsPath) -> Result<(), String> {
    init_cache(path)?;
    let connection = Connection::open(path).map_err(cache_error)?;
    connection
        .execute("DELETE FROM local_tracks", [])
        .map_err(cache_error)?;
    Ok(())
}

fn update_cached_track(path: &FsPath, track: &LocalTrack) -> Result<(), String> {
    let connection = Connection::open(path).map_err(cache_error)?;
    connection
        .execute(
            "UPDATE local_tracks
             SET cover_file = ?1, plain_lyrics = ?2, synced_lyrics = ?3,
                 enrichment_version = ?4
             WHERE path = ?5",
            params![
                track.cover_file,
                track.plain_lyrics,
                track.synced_lyrics,
                track.enrichment_version,
                track.path,
            ],
        )
        .map_err(cache_error)?;
    Ok(())
}

fn save_cache(path: &FsPath, tracks: &[LocalTrack]) -> Result<(), String> {
    let mut connection = Connection::open(path).map_err(cache_error)?;
    let transaction = connection.transaction().map_err(cache_error)?;
    transaction
        .execute("DELETE FROM local_tracks", [])
        .map_err(cache_error)?;
    for track in tracks {
        transaction
            .execute(
                "INSERT INTO local_tracks (
                    path, name, size, modified, title, artist, album, year, duration,
                    cover_file, plain_lyrics, synced_lyrics, enrichment_version
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                params![
                    track.path,
                    track.name,
                    track.size as i64,
                    track.modified as i64,
                    track.title,
                    track.artist,
                    track.album,
                    track.year,
                    track.duration,
                    track.cover_file,
                    track.plain_lyrics,
                    track.synced_lyrics,
                    track.enrichment_version,
                ],
            )
            .map_err(cache_error)?;
    }
    transaction.commit().map_err(cache_error)
}

fn default_source_name() -> String {
    "本地音乐".into()
}

fn cache_error(error: rusqlite::Error) -> String {
    format!("本地曲库缓存操作失败：{error}")
}

pub async fn stream_local(
    State(state): State<SharedWebDavState>,
    Path(token): Path<String>,
    Query(query): Query<LocalStreamQuery>,
    method: Method,
    headers: HeaderMap,
) -> Response {
    if token != state.proxy_token {
        return StatusCode::NOT_FOUND.into_response();
    }
    let Some(root) = state.local_root.read().await.clone() else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "Local library is unavailable",
        )
            .into_response();
    };
    let path = match tokio::fs::canonicalize(&query.path).await {
        Ok(path) if path.starts_with(&root) => path,
        _ => return (StatusCode::FORBIDDEN, "Path is outside the selected folder").into_response(),
    };
    let mut file = match tokio::fs::File::open(&path).await {
        Ok(file) => file,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    let size = match file.metadata().await {
        Ok(metadata) => metadata.len(),
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    let range = headers
        .get(header::RANGE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| parse_range(value, size));
    let (status, start, end) = range
        .map(|(start, end)| (StatusCode::PARTIAL_CONTENT, start, end))
        .unwrap_or((StatusCode::OK, 0, size.saturating_sub(1)));
    let length = if size == 0 { 0 } else { end - start + 1 };
    if start > 0 && file.seek(std::io::SeekFrom::Start(start)).await.is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    let mut builder = Response::builder()
        .status(status)
        .header(
            header::CONTENT_TYPE,
            mime_guess::from_path(&path)
                .first_or_octet_stream()
                .as_ref(),
        )
        .header(header::CONTENT_LENGTH, length)
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CACHE_CONTROL, "private, no-store");
    if status == StatusCode::PARTIAL_CONTENT {
        builder = builder.header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{size}"));
    }
    if method == Method::HEAD || length == 0 {
        return builder
            .body(Body::empty())
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response());
    }
    let stream = ReaderStream::new(file.take(length));
    builder
        .body(Body::from_stream(stream))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

fn parse_range(value: &str, size: u64) -> Option<(u64, u64)> {
    if size == 0 {
        return None;
    }
    let value = value.strip_prefix("bytes=")?;
    if value.contains(',') {
        return None;
    }
    let (start, end) = value.split_once('-')?;
    if start.is_empty() {
        let suffix = end.parse::<u64>().ok()?.min(size);
        return (suffix > 0).then_some((size - suffix, size - 1));
    }
    let start = start.parse::<u64>().ok()?;
    if start >= size {
        return None;
    }
    let end = if end.is_empty() {
        size - 1
    } else {
        end.parse::<u64>().ok()?.min(size - 1)
    };
    (start <= end).then_some((start, end))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_standard_and_suffix_ranges() {
        assert_eq!(parse_range("bytes=10-19", 100), Some((10, 19)));
        assert_eq!(parse_range("bytes=90-", 100), Some((90, 99)));
        assert_eq!(parse_range("bytes=-10", 100), Some((90, 99)));
        assert_eq!(parse_range("bytes=100-", 100), None);
    }
}
