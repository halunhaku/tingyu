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
use tauri_plugin_fs::{FilePath, FsExt, OpenOptions};
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;
use url::Url;
use urlencoding::encode;
use uuid::Uuid;

use crate::{
    android_local, metadata, scraper,
    webdav::{
        remove_source_cache, source_database_path, SharedWebDavState, LEGACY_LOCAL_SOURCE_ID,
    },
};

const MAX_SCAN_DEPTH: usize = 8;
const MAX_SCAN_ENTRIES: usize = 5_000;
const MAX_AUTO_SCRAPES: usize = 24;
const MAX_CONCURRENT_SCRAPES: usize = 8;

#[derive(Clone, Debug)]
pub enum LocalRoot {
    Path(PathBuf),
    ContentUri(String),
}

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
    source_id: String,
    source_name: String,
    folder_path: String,
    folder_name: String,
    tracks: Vec<LocalEntry>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct SavedFolder {
    #[serde(default = "legacy_local_source_id")]
    source_id: String,
    #[serde(default = "default_source_name")]
    name: String,
    folder: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalStreamQuery {
    source_id: String,
    path: String,
}

#[tauri::command]
pub async fn local_library_scan(
    name: String,
    folder: String,
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<LocalScanResult, String> {
    let source_id = Uuid::new_v4().to_string();
    scan_folder(source_id, PathBuf::from(folder), name, &state, true).await
}

#[tauri::command]
pub async fn local_library_scan_android(
    name: String,
    folder: String,
    app: tauri::AppHandle,
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<LocalScanResult, String> {
    let source_id = Uuid::new_v4().to_string();
    let result = scan_android_folder(source_id, folder.clone(), name, &app, &state, true).await;
    if result.is_err()
        && load_folders(&state.local_config_path)
            .is_ok_and(|folders| folders.iter().all(|saved| saved.folder != folder))
    {
        if let Err(error) = android_local::release(&app, &folder) {
            log::warn!("failed to release uncommitted Android folder permission: {error}");
        }
    }
    result
}

#[tauri::command]
pub async fn local_library_restore(
    app: tauri::AppHandle,
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<Vec<LocalScanResult>, String> {
    let mut restored = Vec::new();
    for saved in load_folders(&state.local_config_path)? {
        let result = scan_saved_folder(saved.clone(), &app, &state).await;
        match result {
            Ok(result) => restored.push(result),
            Err(error) => log::warn!("local source {} restore skipped: {error}", saved.name),
        }
    }
    Ok(restored)
}

#[tauri::command]
pub async fn local_library_refresh(
    source_id: String,
    app: tauri::AppHandle,
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<LocalScanResult, String> {
    let saved = load_folders(&state.local_config_path)?
        .into_iter()
        .find(|saved| saved.source_id == source_id)
        .ok_or_else(|| "找不到这个本地音乐源".to_string())?;
    scan_saved_folder(saved, &app, &state).await
}

#[tauri::command]
pub async fn local_library_forget(
    source_id: String,
    app: tauri::AppHandle,
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<(), String> {
    let database_path = source_database_path(&state, &source_id)?;
    let (removed, still_referenced) = remove_folder(&state.local_config_path, &source_id)?;
    state.local_roots.write().await.remove(&source_id);
    if removed.folder.starts_with("content://") && !still_referenced {
        if let Err(error) = android_local::release(&app, &removed.folder) {
            log::warn!("local source {source_id} was removed but SAF cleanup failed: {error}");
        }
    }
    let cleanup = if source_id == LEGACY_LOCAL_SOURCE_ID {
        clear_cache(&database_path)
    } else {
        remove_source_cache(&database_path)
    };
    if let Err(error) = cleanup {
        log::warn!("local source {source_id} was removed but cache cleanup failed: {error}");
    }
    Ok(())
}

#[tauri::command]
pub async fn local_library_scrape_track(
    source_id: String,
    path: String,
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<LocalEntry, String> {
    let root = state
        .local_roots
        .read()
        .await
        .get(&source_id)
        .cloned()
        .ok_or_else(|| "请先选择本地音乐文件夹".to_string())?;
    let database_path = source_database_path(&state, &source_id)?;
    match root {
        LocalRoot::Path(root) => {
            let canonical = std::fs::canonicalize(&path)
                .map_err(|error| format!("无法打开本地音频：{error}"))?;
            if !canonical.starts_with(root) {
                return Err("音频路径超出了已选择的文件夹".into());
            }
        }
        LocalRoot::ContentUri(_) => {
            if !load_cache(&database_path)?.contains_key(&path) {
                return Err("音频不在已授权的 Android 本地曲库中".into());
            }
        }
    }
    init_cache(&database_path)?;
    let mut track = load_cache(&database_path)?
        .remove(&path)
        .ok_or_else(|| "本地曲库中找不到这首歌".to_string())?;
    if track.enrichment_version < scraper::ENRICHMENT_VERSION {
        enrich_track(&mut track, &state).await;
        update_cached_track(&database_path, &track)?;
    }
    Ok(to_entry(&track, &source_id, &state))
}

async fn scan_saved_folder(
    saved: SavedFolder,
    app: &tauri::AppHandle,
    state: &SharedWebDavState,
) -> Result<LocalScanResult, String> {
    if saved.folder.starts_with("content://") {
        scan_android_folder(saved.source_id, saved.folder, saved.name, app, state, false).await
    } else {
        scan_folder(
            saved.source_id,
            PathBuf::from(saved.folder),
            saved.name,
            state,
            false,
        )
        .await
    }
}

async fn scan_folder(
    source_id: String,
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
    let database_path = source_database_path(state, &source_id)?;
    let cover_directory = state.cover_directory.clone();
    let root_for_scan = root.clone();
    let database_for_scan = database_path.clone();
    let build_result = tauri::async_runtime::spawn_blocking(move || {
        build_local_library(&database_for_scan, &cover_directory, &root_for_scan)
    })
    .await
    .map_err(|error| format!("本地曲库扫描任务失败：{error}"))
    .and_then(|result| result);
    let mut tracks = match build_result {
        Ok(tracks) => tracks,
        Err(error) => {
            discard_new_source_cache(&database_path, remember);
            return Err(error);
        }
    };

    enrich_tracks(&mut tracks, state).await;
    if let Err(error) = save_cache(&database_path, &tracks) {
        discard_new_source_cache(&database_path, remember);
        return Err(error);
    }
    if remember {
        if let Err(error) = save_folder(
            &state.local_config_path,
            &source_id,
            &root.to_string_lossy(),
            &source_name,
        ) {
            discard_new_source_cache(&database_path, true);
            return Err(error);
        }
    }
    state
        .local_roots
        .write()
        .await
        .insert(source_id.clone(), LocalRoot::Path(root.clone()));

    let folder_name = root
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("本地音乐")
        .to_string();
    let entries = tracks
        .iter()
        .map(|track| to_entry(track, &source_id, state))
        .collect();
    Ok(LocalScanResult {
        source_id,
        source_name,
        folder_path: root.to_string_lossy().into_owned(),
        folder_name,
        tracks: entries,
    })
}

async fn scan_android_folder(
    source_id: String,
    root_uri: String,
    name: String,
    app: &tauri::AppHandle,
    state: &SharedWebDavState,
    remember: bool,
) -> Result<LocalScanResult, String> {
    if !root_uri.starts_with("content://") {
        return Err("Android 本地文件夹授权地址无效".into());
    }
    let source_name = if name.trim().is_empty() {
        default_source_name()
    } else {
        name.trim().to_string()
    };
    let app_for_scan = app.clone();
    let root_for_scan = root_uri.clone();
    let scanned = tauri::async_runtime::spawn_blocking(move || {
        android_local::scan(&app_for_scan, &root_for_scan)
    })
    .await
    .map_err(|error| format!("Android 曲库扫描任务失败：{error}"))??;

    let database_path = source_database_path(state, &source_id)?;
    let database_for_scan = database_path.clone();
    let cover_directory = state.cover_directory.clone();
    let app_for_metadata = app.clone();
    let build_result = tauri::async_runtime::spawn_blocking(move || {
        build_android_library(
            &database_for_scan,
            &cover_directory,
            &app_for_metadata,
            scanned.files,
        )
    })
    .await
    .map_err(|error| format!("Android 曲库标签读取任务失败：{error}"))
    .and_then(|result| result);
    let mut tracks = match build_result {
        Ok(tracks) => tracks,
        Err(error) => {
            discard_new_source_cache(&database_path, remember);
            return Err(error);
        }
    };

    enrich_tracks(&mut tracks, state).await;
    if let Err(error) = save_cache(&database_path, &tracks) {
        discard_new_source_cache(&database_path, remember);
        return Err(error);
    }
    if remember {
        if let Err(error) = save_folder(
            &state.local_config_path,
            &source_id,
            &root_uri,
            &source_name,
        ) {
            discard_new_source_cache(&database_path, true);
            return Err(error);
        }
    }
    state
        .local_roots
        .write()
        .await
        .insert(source_id.clone(), LocalRoot::ContentUri(root_uri.clone()));

    let entries = tracks
        .iter()
        .map(|track| to_entry(track, &source_id, state))
        .collect();
    Ok(LocalScanResult {
        source_id,
        source_name,
        folder_path: root_uri,
        folder_name: scanned.name,
        tracks: entries,
    })
}

fn discard_new_source_cache(database_path: &FsPath, remember: bool) {
    if remember {
        if let Err(error) = remove_source_cache(database_path) {
            log::warn!("failed to discard uncommitted local source cache: {error}");
        }
    }
}

async fn enrich_tracks(tracks: &mut [LocalTrack], state: &SharedWebDavState) {
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
}

fn build_android_library(
    database_path: &FsPath,
    cover_directory: &FsPath,
    app: &tauri::AppHandle,
    files: Vec<android_local::AndroidFile>,
) -> Result<Vec<LocalTrack>, String> {
    init_cache(database_path)?;
    let existing = load_cache(database_path)?;
    let mut tracks = Vec::with_capacity(files.len());
    for entry in files {
        if let Some(cached) = existing.get(&entry.uri) {
            if cached.size == entry.size && cached.modified == entry.modified {
                tracks.push(cached.clone());
                continue;
            }
        }

        let cache_key = format!("local:{}:{}", entry.uri, entry.modified);
        let extracted = open_android_file(app, &entry.uri)
            .and_then(|file| metadata::extract_local_reader(file, &cache_key, cover_directory))
            .unwrap_or_else(|error| {
                log::warn!(
                    "Android local metadata extraction skipped for {}: {error}",
                    entry.name
                );
                metadata::ExtractedMetadata::default()
            });
        let (fallback_artist, fallback_title) = title_from_filename(&entry.name);
        tracks.push(LocalTrack {
            path: entry.uri,
            name: entry.name,
            size: entry.size,
            modified: entry.modified,
            title: extracted.title.unwrap_or(fallback_title),
            artist: extracted.artist.unwrap_or(fallback_artist),
            album: extracted.album.unwrap_or(entry.album),
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

fn open_android_file(app: &tauri::AppHandle, uri: &str) -> Result<std::fs::File, String> {
    let url = Url::parse(uri).map_err(|error| format!("Android 音频 URI 无效：{error}"))?;
    app.fs()
        .open(FilePath::Url(url), OpenOptions::default())
        .map_err(|error| format!("无法打开 Android 音频：{error}"))
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

fn to_entry(track: &LocalTrack, source_id: &str, state: &SharedWebDavState) -> LocalEntry {
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
            "{}/local/{}?sourceId={}&path={}",
            state.proxy_origin,
            state.proxy_token,
            encode(source_id),
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

fn load_folders(path: &FsPath) -> Result<Vec<SavedFolder>, String> {
    let content = match std::fs::read_to_string(path) {
        Ok(content) => content,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(format!("无法读取本地音乐源配置：{error}")),
    };
    if let Ok(folders) = serde_json::from_str::<Vec<SavedFolder>>(&content) {
        return Ok(folders);
    }
    serde_json::from_str::<SavedFolder>(&content)
        .map(|folder| vec![folder])
        .map_err(|error| format!("本地音乐源配置无效：{error}"))
}

fn save_folders(path: &FsPath, folders: &[SavedFolder]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("无法创建本地音乐源配置目录：{error}"))?;
    }
    let content = serde_json::to_vec_pretty(folders)
        .map_err(|error| format!("无法保存本地音乐源配置：{error}"))?;
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, content)
        .map_err(|error| format!("无法保存本地音乐源配置：{error}"))?;
    std::fs::rename(temporary, path).map_err(|error| format!("无法保存本地音乐源配置：{error}"))
}

fn save_folder(path: &FsPath, source_id: &str, root: &str, name: &str) -> Result<(), String> {
    let mut folders = load_folders(path)?;
    let folder = SavedFolder {
        source_id: source_id.to_string(),
        name: name.to_string(),
        folder: root.to_string(),
    };
    if let Some(existing) = folders
        .iter_mut()
        .find(|existing| existing.source_id == source_id)
    {
        *existing = folder;
    } else {
        folders.push(folder);
    }
    save_folders(path, &folders)
}

fn remove_folder(path: &FsPath, source_id: &str) -> Result<(SavedFolder, bool), String> {
    let mut folders = load_folders(path)?;
    let index = folders
        .iter()
        .position(|folder| folder.source_id == source_id)
        .ok_or_else(|| "找不到这个本地音乐源".to_string())?;
    let removed = folders.remove(index);
    let still_referenced = folders.iter().any(|folder| folder.folder == removed.folder);
    save_folders(path, &folders)?;
    Ok((removed, still_referenced))
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

fn legacy_local_source_id() -> String {
    LEGACY_LOCAL_SOURCE_ID.into()
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
    let Some(root) = state
        .local_roots
        .read()
        .await
        .get(&query.source_id)
        .cloned()
    else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "Local library is unavailable",
        )
            .into_response();
    };
    let database_path = match source_database_path(&state, &query.source_id) {
        Ok(path) => path,
        Err(_) => return StatusCode::FORBIDDEN.into_response(),
    };
    let (mut file, size, mime_name) = match root {
        LocalRoot::Path(root) => {
            let path = match tokio::fs::canonicalize(&query.path).await {
                Ok(path) if path.starts_with(&root) => path,
                _ => {
                    return (StatusCode::FORBIDDEN, "Path is outside the selected folder")
                        .into_response();
                }
            };
            let file = match tokio::fs::File::open(&path).await {
                Ok(file) => file,
                Err(_) => return StatusCode::NOT_FOUND.into_response(),
            };
            let size = match file.metadata().await {
                Ok(metadata) => metadata.len(),
                Err(_) => return StatusCode::NOT_FOUND.into_response(),
            };
            (file, size, path.to_string_lossy().into_owned())
        }
        LocalRoot::ContentUri(root_uri) => {
            if !root_uri.starts_with("content://") {
                return StatusCode::FORBIDDEN.into_response();
            }
            let cached = match load_cache(&database_path)
                .ok()
                .and_then(|tracks| tracks.get(&query.path).cloned())
            {
                Some(track) => track,
                None => return StatusCode::FORBIDDEN.into_response(),
            };
            let file = match open_android_file(&state.app_handle, &query.path) {
                Ok(file) => file,
                Err(_) => return StatusCode::NOT_FOUND.into_response(),
            };
            let actual_size = file.metadata().map_or(0, |metadata| metadata.len());
            (
                tokio::fs::File::from_std(file),
                actual_size.max(cached.size),
                cached.name,
            )
        }
    };
    let range = match requested_range(&headers, size) {
        Ok(range) => range,
        Err(()) => return range_not_satisfiable(size),
    };
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
            mime_guess::from_path(&mime_name)
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

fn requested_range(headers: &HeaderMap, size: u64) -> Result<Option<(u64, u64)>, ()> {
    let Some(value) = headers.get(header::RANGE) else {
        return Ok(None);
    };
    let value = value.to_str().map_err(|_| ())?;
    parse_range(value, size).map(Some).ok_or(())
}

fn range_not_satisfiable(size: u64) -> Response {
    Response::builder()
        .status(StatusCode::RANGE_NOT_SATISFIABLE)
        .header(header::CONTENT_RANGE, format!("bytes */{size}"))
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_LENGTH, 0)
        .header(header::CACHE_CONTROL, "private, no-store")
        .body(Body::empty())
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

    #[test]
    fn rejects_unsatisfiable_range_requests_with_416() {
        let mut headers = HeaderMap::new();
        headers.insert(header::RANGE, "bytes=100-".parse().unwrap());
        assert_eq!(requested_range(&headers, 100), Err(()));

        let response = range_not_satisfiable(100);
        assert_eq!(response.status(), StatusCode::RANGE_NOT_SATISFIABLE);
        assert_eq!(response.headers()[header::CONTENT_RANGE], "bytes */100");
    }

    #[test]
    fn migrates_single_folder_config_and_keeps_multiple_sources() {
        let path = std::env::temp_dir().join(format!("tingyu-folders-{}.json", Uuid::new_v4()));
        std::fs::write(&path, r#"{"name":"旧曲库","folder":"/music/legacy"}"#).unwrap();

        let legacy = load_folders(&path).unwrap();
        assert_eq!(legacy.len(), 1);
        assert_eq!(legacy[0].source_id, LEGACY_LOCAL_SOURCE_ID);

        let source_id = Uuid::new_v4().to_string();
        save_folder(&path, &source_id, "/music/new", "新曲库").unwrap();
        let folders = load_folders(&path).unwrap();
        assert_eq!(folders.len(), 2);
        assert!(folders.iter().any(|folder| folder.source_id == source_id));
        assert!(folders
            .iter()
            .any(|folder| folder.source_id == LEGACY_LOCAL_SOURCE_ID));
        let (removed, still_referenced) = remove_folder(&path, &source_id).unwrap();
        assert_eq!(removed.folder, "/music/new");
        assert!(!still_referenced);
        let folders = load_folders(&path).unwrap();
        assert!(!folders.iter().any(|folder| folder.source_id == source_id));
        assert!(remove_folder(&path, &source_id).is_err());

        let first_id = Uuid::new_v4().to_string();
        let second_id = Uuid::new_v4().to_string();
        save_folder(&path, &first_id, "content://music", "首个授权").unwrap();
        save_folder(&path, &second_id, "content://music", "重复授权").unwrap();
        let (_, still_referenced) = remove_folder(&path, &first_id).unwrap();
        assert!(still_referenced);
        let (_, still_referenced) = remove_folder(&path, &second_id).unwrap();
        assert!(!still_referenced);

        let _ = std::fs::remove_file(path);
    }
}
