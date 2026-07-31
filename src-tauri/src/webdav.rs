use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};

use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::{header, HeaderMap, HeaderValue, Method, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use futures_util::{stream, StreamExt};
use reqwest::{Client, Url};
use roxmltree::{Document, Node};
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;
use tower_http::cors::CorsLayer;
use uuid::Uuid;

use crate::{credentials, library_cache, local_library, metadata, scraper};
use library_cache::CachedTrack;

const PROPFIND_BODY: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:displayname />
    <d:resourcetype />
    <d:getcontentlength />
    <d:getcontenttype />
    <d:getlastmodified />
    <d:getetag />
  </d:prop>
</d:propfind>"#;
const MAX_SCAN_DEPTH: usize = 8;
const MAX_SCAN_ENTRIES: usize = 5_000;
const MAX_AUTO_SCRAPES_PER_SCAN: usize = 24;
const MAX_CONCURRENT_SCRAPES: usize = 8;

#[derive(Clone)]
pub struct WebDavSession {
    client: Client,
    base_url: Url,
    username: String,
    password: String,
}

pub const LEGACY_WEBDAV_SOURCE_ID: &str = "legacy-webdav";
pub const LEGACY_LOCAL_SOURCE_ID: &str = "legacy-local";

pub struct WebDavState {
    pub app_handle: tauri::AppHandle,
    pub sessions: RwLock<HashMap<String, WebDavSession>>,
    pub proxy_origin: String,
    pub proxy_token: String,
    pub database_path: PathBuf,
    pub source_cache_directory: PathBuf,
    pub cover_directory: PathBuf,
    pub connection_path: PathBuf,
    pub connection_directory: PathBuf,
    pub local_config_path: PathBuf,
    pub local_roots: RwLock<HashMap<String, local_library::LocalRoot>>,
    pub scraper_client: Client,
}

pub type SharedWebDavState = Arc<WebDavState>;

pub fn source_database_path(state: &WebDavState, source_id: &str) -> Result<PathBuf, String> {
    if is_legacy_source(source_id) {
        return Ok(state.database_path.clone());
    }
    Uuid::parse_str(source_id).map_err(|_| "音乐源 ID 无效".to_string())?;
    Ok(state
        .source_cache_directory
        .join(format!("{source_id}.sqlite3")))
}

pub fn remove_source_cache(path: &std::path::Path) -> Result<(), String> {
    for candidate in [
        path.to_path_buf(),
        PathBuf::from(format!("{}-wal", path.display())),
        PathBuf::from(format!("{}-shm", path.display())),
    ] {
        match std::fs::remove_file(candidate) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("无法删除音乐源缓存：{error}")),
        }
    }
    Ok(())
}

fn is_legacy_source(source_id: &str) -> bool {
    matches!(source_id, LEGACY_WEBDAV_SOURCE_ID | LEGACY_LOCAL_SOURCE_ID)
}

fn connection_path_for(state: &WebDavState, source_id: &str) -> PathBuf {
    if source_id == LEGACY_WEBDAV_SOURCE_ID {
        state.connection_path.clone()
    } else {
        state.connection_directory.join(format!("{source_id}.json"))
    }
}

fn saved_connection_paths(state: &WebDavState) -> Result<Vec<(String, PathBuf)>, String> {
    let mut paths = Vec::new();
    if state.connection_path.exists() {
        paths.push((
            LEGACY_WEBDAV_SOURCE_ID.into(),
            state.connection_path.clone(),
        ));
    }
    let entries = std::fs::read_dir(&state.connection_directory)
        .map_err(|error| format!("无法读取 WebDAV 音乐源配置：{error}"))?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        let Some(source_id) = path
            .file_stem()
            .and_then(|value| value.to_str())
            .filter(|value| Uuid::parse_str(value).is_ok())
        else {
            continue;
        };
        paths.push((source_id.to_string(), path));
    }
    paths.sort_by(|left, right| left.0.cmp(&right.0));
    Ok(paths)
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebDavConfig {
    #[serde(default = "default_source_name")]
    pub name: String,
    pub base_url: String,
    pub username: String,
    pub password: String,
    #[serde(default)]
    pub folder: String,
    #[serde(default = "default_true")]
    pub remember: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionInfo {
    pub source_id: String,
    pub name: String,
    pub base_url: String,
    pub server_name: String,
    pub folder: String,
    pub restored: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebDavEntry {
    pub name: String,
    pub href: String,
    pub size: u64,
    pub content_type: Option<String>,
    pub modified: Option<String>,
    pub etag: Option<String>,
    pub is_directory: bool,
    pub stream_url: Option<String>,
    pub artwork_url: Option<String>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub year: Option<u32>,
    pub duration: f64,
    pub plain_lyrics: Option<String>,
    pub synced_lyrics: Option<String>,
    pub enrichment_version: u32,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanResult {
    pub tracks: Vec<WebDavEntry>,
    pub stats: ScanStats,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CachedLibrary {
    pub source_id: String,
    pub name: String,
    pub tracks: Vec<WebDavEntry>,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanStats {
    pub added: usize,
    pub updated: usize,
    pub unchanged: usize,
    pub removed: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StreamQuery {
    source_id: String,
    href: String,
}

pub fn create_state(
    app_handle: tauri::AppHandle,
    port: u16,
    database_path: PathBuf,
    cover_directory: PathBuf,
    connection_path: PathBuf,
    local_config_path: PathBuf,
) -> Result<SharedWebDavState, String> {
    library_cache::init(&database_path)?;
    let app_data_directory = database_path
        .parent()
        .ok_or_else(|| "无法确定应用数据目录".to_string())?;
    let source_cache_directory = app_data_directory.join("source-caches");
    let connection_directory = app_data_directory.join("webdav-connections");
    std::fs::create_dir_all(&source_cache_directory)
        .map_err(|error| format!("无法创建音乐源缓存目录：{error}"))?;
    std::fs::create_dir_all(&connection_directory)
        .map_err(|error| format!("无法创建 WebDAV 配置目录：{error}"))?;
    let scraper_client = Client::builder()
        .user_agent("Tingyu/0.3 Music Metadata Scraper")
        .timeout(Duration::from_secs(4))
        .build()
        .map_err(|error| format!("无法创建元数据刮削客户端：{error}"))?;
    Ok(Arc::new(WebDavState {
        app_handle,
        sessions: RwLock::new(HashMap::new()),
        proxy_origin: format!("http://127.0.0.1:{port}"),
        proxy_token: Uuid::new_v4().to_string(),
        database_path,
        source_cache_directory,
        cover_directory,
        connection_path,
        connection_directory,
        local_config_path,
        local_roots: RwLock::new(HashMap::new()),
        scraper_client,
    }))
}

pub async fn enrich_cached_library(state: SharedWebDavState) {
    let tracks = match library_cache::load_all(&state.database_path) {
        Ok(tracks) => tracks,
        Err(error) => {
            log::warn!("cached metadata enrichment skipped: {error}");
            return;
        }
    };
    let enriched = stream::iter(
        tracks
            .into_iter()
            .filter(|track| track.enrichment_version < scraper::ENRICHMENT_VERSION)
            .take(MAX_AUTO_SCRAPES_PER_SCAN)
            .map(|mut track| {
                let state = state.clone();
                async move {
                    enrich_cached_track(&mut track, &state).await;
                    track
                }
            }),
    )
    .buffer_unordered(MAX_CONCURRENT_SCRAPES)
    .collect::<Vec<_>>()
    .await;
    for track in enriched {
        if let Err(error) = library_cache::update_enrichment(&state.database_path, &track) {
            log::warn!(
                "failed to save scraped metadata for {}: {error}",
                track.name
            );
        }
    }
}

pub fn proxy_router(state: SharedWebDavState) -> Router {
    Router::new()
        .route("/stream/{token}", get(stream_audio).head(stream_audio))
        .route("/cover/{token}/{filename}", get(serve_cover))
        .route(
            "/local/{token}",
            get(local_library::stream_local).head(local_library::stream_local),
        )
        .layer(CorsLayer::permissive())
        .with_state(state)
}

#[tauri::command]
pub async fn webdav_connect(
    config: WebDavConfig,
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<ConnectionInfo, String> {
    let source_id = Uuid::new_v4().to_string();
    let (session, mut info) = establish_session(&config, &source_id).await?;
    if config.remember {
        credentials::save(
            &connection_path_for(&state, &source_id),
            &credentials::SavedConnection {
                name: config.name.clone(),
                base_url: info.base_url.clone(),
                username: config.username.clone(),
                folder: config.folder.clone(),
            },
            &config.password,
        )?;
    }
    state.sessions.write().await.insert(source_id, session);
    info.folder.clone_from(&config.folder);
    Ok(info)
}

#[tauri::command]
pub async fn webdav_restore(
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<Vec<ConnectionInfo>, String> {
    let mut restored = Vec::new();
    for (source_id, path) in saved_connection_paths(&state)? {
        let (saved, password) = match credentials::load(&path) {
            Ok(Some(connection)) => connection,
            Ok(None) => continue,
            Err(error) => {
                log::warn!("WebDAV credentials for {source_id} could not be loaded: {error}");
                continue;
            }
        };
        let config = WebDavConfig {
            name: saved.name,
            base_url: saved.base_url,
            username: saved.username,
            password,
            folder: saved.folder,
            remember: false,
        };
        match establish_session(&config, &source_id).await {
            Ok((session, mut info)) => {
                info.folder.clone_from(&config.folder);
                info.restored = true;
                state.sessions.write().await.insert(source_id, session);
                restored.push(info);
            }
            Err(error) => log::warn!("WebDAV source {} restore skipped: {error}", config.name),
        }
    }
    Ok(restored)
}

#[tauri::command]
pub async fn webdav_forget(
    source_id: String,
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<(), String> {
    state.sessions.write().await.remove(&source_id);
    credentials::forget(&connection_path_for(&state, &source_id))?;
    let database_path = source_database_path(&state, &source_id)?;
    if is_legacy_source(&source_id) {
        library_cache::clear_all(&database_path)
    } else {
        remove_source_cache(&database_path)
    }
}

#[tauri::command]
pub async fn webdav_cached_library(
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<Vec<CachedLibrary>, String> {
    let mut libraries = Vec::new();
    for (source_id, path) in saved_connection_paths(&state)? {
        let saved = match credentials::load_saved(&path) {
            Ok(Some(saved)) => saved,
            Ok(None) => continue,
            Err(error) => {
                log::warn!("WebDAV config for {source_id} could not be loaded: {error}");
                continue;
            }
        };
        let database_path = source_database_path(&state, &source_id)?;
        if let Err(error) = library_cache::init(&database_path) {
            log::warn!("WebDAV cache for {source_id} could not be opened: {error}");
            continue;
        }
        let cached = match library_cache::load_all(&database_path) {
            Ok(cached) => cached,
            Err(error) => {
                log::warn!("WebDAV cache for {source_id} could not be loaded: {error}");
                continue;
            }
        };
        libraries.push(CachedLibrary {
            source_id: source_id.clone(),
            name: saved.name,
            tracks: cached
                .iter()
                .map(|track| cached_to_entry(track, &source_id, &state))
                .collect(),
        });
    }
    Ok(libraries)
}

#[tauri::command]
pub async fn webdav_update_duration(
    source_id: String,
    href: String,
    duration: f64,
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<(), String> {
    if !duration.is_finite() || duration <= 0.0 {
        return Ok(());
    }
    library_cache::update_duration(&source_database_path(&state, &source_id)?, &href, duration)
}

#[tauri::command]
pub async fn webdav_scrape_track(
    source_id: String,
    href: String,
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<WebDavEntry, String> {
    let database_path = source_database_path(&state, &source_id)?;
    let mut track = library_cache::load_map(&database_path)?
        .remove(&href)
        .ok_or_else(|| "曲库中找不到这首歌".to_string())?;
    if track.enrichment_version < scraper::ENRICHMENT_VERSION {
        enrich_cached_track(&mut track, &state).await;
        library_cache::update_enrichment(&database_path, &track)?;
    }
    Ok(cached_to_entry(&track, &source_id, &state))
}

#[tauri::command]
pub async fn webdav_scan(
    source_id: String,
    folder: Option<String>,
    recursive: Option<bool>,
    state: tauri::State<'_, SharedWebDavState>,
) -> Result<ScanResult, String> {
    let session = state
        .sessions
        .read()
        .await
        .get(&source_id)
        .cloned()
        .ok_or_else(|| "请先连接这个 WebDAV 音乐源".to_string())?;
    let database_path = source_database_path(&state, &source_id)?;
    library_cache::init(&database_path)?;
    let root = join_relative_path(&session.base_url, folder.as_deref().unwrap_or(""))?;
    let should_recurse = recursive.unwrap_or(true);
    let existing = library_cache::load_map(&database_path)?;
    let remote_files = collect_audio_files(&session, root, should_recurse).await?;
    let mut stats = ScanStats::default();
    let mut cached_tracks = Vec::with_capacity(remote_files.len());
    let mut scrape_candidates = Vec::new();

    for entry in remote_files {
        let previous = existing.get(&entry.href);
        let is_unchanged = previous.is_some_and(|cached| fingerprint_matches(cached, &entry));
        let cached = if is_unchanged {
            stats.unchanged += 1;
            previous.expect("checked above").clone()
        } else {
            if previous.is_some() {
                stats.updated += 1;
            } else {
                stats.added += 1;
            }
            let remote_url = resolve_href(&session.base_url, &entry.href)?;
            let cache_key = format!(
                "{}:{}:{}",
                source_id,
                entry.href,
                entry
                    .etag
                    .as_deref()
                    .or(entry.modified.as_deref())
                    .unwrap_or("")
            );
            let extracted = metadata::extract(
                &session.client,
                &remote_url,
                &session.username,
                &session.password,
                &entry.name,
                &cache_key,
                &state.cover_directory,
            )
            .await
            .unwrap_or_else(|error| {
                log::warn!("metadata extraction skipped for {}: {error}", entry.name);
                metadata::ExtractedMetadata::default()
            });
            let (fallback_artist, fallback_title) = title_from_filename(&entry.name);
            let title = extracted.title.unwrap_or(fallback_title);
            let artist = extracted.artist.unwrap_or(fallback_artist);
            let album = extracted
                .album
                .unwrap_or_else(|| parent_name_from_href(&entry.href));
            CachedTrack {
                href: entry.href.clone(),
                name: entry.name.clone(),
                size: entry.size,
                modified: entry.modified.clone(),
                etag: entry.etag.clone(),
                content_type: entry.content_type.clone(),
                title,
                artist,
                album,
                year: extracted.year,
                duration: if extracted.duration > 0.0 {
                    extracted.duration
                } else {
                    previous.map_or(0.0, |track| track.duration)
                },
                cover_file: extracted.cover_file,
                plain_lyrics: extracted.plain_lyrics,
                synced_lyrics: None,
                enrichment_version: 0,
            }
        };
        let index = cached_tracks.len();
        if cached.enrichment_version < scraper::ENRICHMENT_VERSION
            && scrape_candidates.len() < MAX_AUTO_SCRAPES_PER_SCAN
        {
            scrape_candidates.push(index);
        }
        cached_tracks.push(cached);
    }

    let shared_state = state.inner().clone();
    let enriched = stream::iter(scrape_candidates.into_iter().map(|index| {
        let shared_state = shared_state.clone();
        let mut track = cached_tracks[index].clone();
        async move {
            enrich_cached_track(&mut track, &shared_state).await;
            (index, track)
        }
    }))
    .buffer_unordered(MAX_CONCURRENT_SCRAPES)
    .collect::<Vec<_>>()
    .await;
    for (index, track) in enriched {
        cached_tracks[index] = track;
    }

    let scan_id = Uuid::new_v4().to_string();
    stats.removed = library_cache::save_scan(&database_path, &cached_tracks, &scan_id)?;
    let tracks = cached_tracks
        .iter()
        .map(|track| cached_to_entry(track, &source_id, &state))
        .collect();
    Ok(ScanResult { tracks, stats })
}

async fn establish_session(
    config: &WebDavConfig,
    source_id: &str,
) -> Result<(WebDavSession, ConnectionInfo), String> {
    let mut base_url =
        Url::parse(config.base_url.trim()).map_err(|_| "WebDAV 地址格式不正确".to_string())?;
    if !matches!(base_url.scheme(), "http" | "https") {
        return Err("WebDAV 地址必须使用 HTTP 或 HTTPS".into());
    }
    if !base_url.path().ends_with('/') {
        base_url.set_path(&format!("{}/", base_url.path()));
    }
    base_url.set_query(None);
    base_url.set_fragment(None);
    let client = Client::builder()
        .user_agent("Tingyu/0.2 WebDAV Music Player")
        .redirect(reqwest::redirect::Policy::limited(5))
        .build()
        .map_err(|error| format!("无法创建网络客户端：{error}"))?;
    let session = WebDavSession {
        client,
        base_url: base_url.clone(),
        username: config.username.clone(),
        password: config.password.clone(),
    };
    propfind(&session, base_url.clone(), "0").await?;
    let info = ConnectionInfo {
        source_id: source_id.to_string(),
        name: config.name.trim().to_string(),
        server_name: base_url.host_str().unwrap_or("WebDAV").to_string(),
        base_url: base_url.to_string(),
        folder: config.folder.clone(),
        restored: false,
    };
    Ok((session, info))
}

async fn collect_audio_files(
    session: &WebDavSession,
    root: Url,
    recursive: bool,
) -> Result<Vec<WebDavEntry>, String> {
    let mut queue = VecDeque::from([(root, 0usize)]);
    let mut visited = HashSet::new();
    let mut audio_files = Vec::new();

    while let Some((folder_url, depth)) = queue.pop_front() {
        if !visited.insert(folder_url.to_string()) {
            continue;
        }
        for mut entry in propfind(session, folder_url.clone(), "1").await? {
            let entry_url = resolve_href(&session.base_url, &entry.href)?;
            ensure_allowed_url(session, &entry_url)?;
            if normalize_path(entry_url.path()) == normalize_path(folder_url.path()) {
                continue;
            }
            if entry.is_directory {
                if recursive && depth < MAX_SCAN_DEPTH {
                    queue.push_back((entry_url, depth + 1));
                }
            } else if is_audio_file(&entry.name, entry.content_type.as_deref()) {
                entry.href = entry_url.to_string();
                audio_files.push(entry);
                if audio_files.len() >= MAX_SCAN_ENTRIES {
                    return Err(format!(
                        "曲库超过 {MAX_SCAN_ENTRIES} 首，暂时无法完成安全的增量扫描"
                    ));
                }
            }
        }
    }
    Ok(audio_files)
}

async fn propfind(
    session: &WebDavSession,
    url: Url,
    depth: &str,
) -> Result<Vec<WebDavEntry>, String> {
    let method = reqwest::Method::from_bytes(b"PROPFIND").expect("valid PROPFIND method");
    let response = session
        .client
        .request(method, url)
        .basic_auth(&session.username, Some(&session.password))
        .header("Depth", depth)
        .header(
            reqwest::header::CONTENT_TYPE,
            "application/xml; charset=utf-8",
        )
        .body(PROPFIND_BODY)
        .send()
        .await
        .map_err(|error| format!("无法连接 WebDAV：{error}"))?;
    let status = response.status();
    if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
        return Err("WebDAV 认证失败，请检查账号和应用密码".into());
    }
    if !status.is_success() && status.as_u16() != 207 {
        return Err(format!("WebDAV 返回错误状态：{status}"));
    }
    let xml = response
        .text()
        .await
        .map_err(|error| format!("无法读取 WebDAV 响应：{error}"))?;
    parse_multistatus(&xml)
}

fn parse_multistatus(xml: &str) -> Result<Vec<WebDavEntry>, String> {
    let document =
        Document::parse(xml).map_err(|error| format!("WebDAV XML 响应无法解析：{error}"))?;
    let mut entries = Vec::new();
    for response in document
        .descendants()
        .filter(|node| has_name(*node, "response"))
    {
        let href = descendant_text(response, "href").unwrap_or_default();
        if href.is_empty() {
            continue;
        }
        let name = descendant_text(response, "displayname")
            .filter(|name| !name.trim().is_empty())
            .unwrap_or_else(|| file_name_from_href(&href));
        entries.push(WebDavEntry {
            name,
            href,
            size: descendant_text(response, "getcontentlength")
                .and_then(|value| value.parse().ok())
                .unwrap_or(0),
            content_type: descendant_text(response, "getcontenttype"),
            modified: descendant_text(response, "getlastmodified"),
            etag: descendant_text(response, "getetag"),
            is_directory: response
                .descendants()
                .any(|node| has_name(node, "collection")),
            stream_url: None,
            artwork_url: None,
            title: None,
            artist: None,
            album: None,
            year: None,
            duration: 0.0,
            plain_lyrics: None,
            synced_lyrics: None,
            enrichment_version: 0,
        });
    }
    Ok(entries)
}

fn cached_to_entry(track: &CachedTrack, source_id: &str, state: &WebDavState) -> WebDavEntry {
    WebDavEntry {
        name: track.name.clone(),
        href: track.href.clone(),
        size: track.size,
        content_type: track.content_type.clone(),
        modified: track.modified.clone(),
        etag: track.etag.clone(),
        is_directory: false,
        stream_url: Some(format!(
            "{}/stream/{}?sourceId={}&href={}",
            state.proxy_origin,
            state.proxy_token,
            urlencoding::encode(source_id),
            urlencoding::encode(&track.href)
        )),
        artwork_url: track.cover_file.as_ref().map(|filename| {
            format!(
                "{}/cover/{}/{}",
                state.proxy_origin, state.proxy_token, filename
            )
        }),
        title: Some(track.title.clone()),
        artist: Some(track.artist.clone()),
        album: Some(track.album.clone()),
        year: track.year,
        duration: track.duration,
        plain_lyrics: track.plain_lyrics.clone(),
        synced_lyrics: track.synced_lyrics.clone(),
        enrichment_version: track.enrichment_version,
    }
}

async fn enrich_cached_track(track: &mut CachedTrack, state: &WebDavState) {
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

fn fingerprint_matches(cached: &CachedTrack, remote: &WebDavEntry) -> bool {
    if cached.size != remote.size {
        return false;
    }
    match (&remote.etag, &cached.etag) {
        (Some(remote), Some(cached)) => remote == cached,
        _ => remote.modified.is_some() && remote.modified == cached.modified,
    }
}

fn title_from_filename(name: &str) -> (String, String) {
    let filename = name.rsplit_once('.').map_or(name, |(stem, _)| stem);
    if let Some((artist, title)) = filename.split_once(" - ") {
        (artist.trim().to_string(), title.trim().to_string())
    } else {
        ("未知艺术家".into(), filename.to_string())
    }
}

fn parent_name_from_href(href: &str) -> String {
    Url::parse(href)
        .ok()
        .and_then(|url| {
            let mut segments = url.path_segments()?.rev();
            segments.next()?;
            let parent = segments.next()?;
            urlencoding::decode(parent)
                .ok()
                .map(|value| value.into_owned())
        })
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "WebDAV 曲库".into())
}

fn has_name(node: Node<'_, '_>, name: &str) -> bool {
    node.is_element() && node.tag_name().name().eq_ignore_ascii_case(name)
}

fn descendant_text(node: Node<'_, '_>, name: &str) -> Option<String> {
    node.descendants()
        .find(|child| has_name(*child, name))
        .and_then(|child| child.text())
        .map(|text| text.trim().to_string())
}

fn file_name_from_href(href: &str) -> String {
    let path = Url::parse(href)
        .map(|url| url.path().to_string())
        .unwrap_or_else(|_| href.to_string());
    let segment = path
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("未命名音频");
    urlencoding::decode(segment)
        .map(|value| value.into_owned())
        .unwrap_or_else(|_| segment.to_string())
}

fn join_relative_path(base: &Url, path: &str) -> Result<Url, String> {
    if path.trim().is_empty() || path.trim() == "/" {
        return Ok(base.clone());
    }
    let mut url = base.clone();
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| "WebDAV 地址不能作为目录使用".to_string())?;
        segments.pop_if_empty();
        for segment in path
            .trim_matches('/')
            .split('/')
            .filter(|part| !part.is_empty())
        {
            if matches!(segment, "." | "..") {
                return Err("目录中不能包含相对路径".into());
            }
            segments.push(segment);
        }
        segments.push("");
    }
    Ok(url)
}

fn resolve_href(base: &Url, href: &str) -> Result<Url, String> {
    Url::parse(href)
        .or_else(|_| base.join(href))
        .map_err(|_| format!("WebDAV 返回了无效路径：{href}"))
}

fn ensure_allowed_url(session: &WebDavSession, url: &Url) -> Result<(), String> {
    if url.scheme() != session.base_url.scheme()
        || url.host_str() != session.base_url.host_str()
        || url.port_or_known_default() != session.base_url.port_or_known_default()
        || !normalize_path(url.path()).starts_with(&normalize_path(session.base_url.path()))
    {
        return Err("WebDAV 返回的文件地址超出了已授权目录".into());
    }
    Ok(())
}

fn normalize_path(path: &str) -> String {
    format!("{}/", path.trim_end_matches('/'))
}

fn is_audio_file(name: &str, content_type: Option<&str>) -> bool {
    if content_type.is_some_and(|kind| kind.to_ascii_lowercase().starts_with("audio/")) {
        return true;
    }
    matches!(
        name.rsplit('.')
            .next()
            .unwrap_or("")
            .to_ascii_lowercase()
            .as_str(),
        "mp3" | "flac" | "m4a" | "aac" | "wav" | "ogg" | "opus"
    )
}

async fn serve_cover(
    State(state): State<SharedWebDavState>,
    Path((token, filename)): Path<(String, String)>,
) -> Response {
    if token != state.proxy_token
        || filename.is_empty()
        || !filename
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '.')
    {
        return StatusCode::NOT_FOUND.into_response();
    }
    let bytes = match tokio::fs::read(state.cover_directory.join(&filename)).await {
        Ok(bytes) => bytes,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    let content_type = match filename.rsplit('.').next().unwrap_or("") {
        "png" => "image/png",
        "gif" => "image/gif",
        "bmp" => "image/bmp",
        "tif" => "image/tiff",
        "webp" => "image/webp",
        _ => "image/jpeg",
    };
    Response::builder()
        .header(header::CONTENT_TYPE, content_type)
        .header(
            header::CACHE_CONTROL,
            "private, max-age=31536000, immutable",
        )
        .body(Body::from(bytes))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

async fn stream_audio(
    State(state): State<SharedWebDavState>,
    Path(token): Path<String>,
    Query(query): Query<StreamQuery>,
    method: Method,
    request_headers: HeaderMap,
) -> Response {
    if token != state.proxy_token {
        return (StatusCode::NOT_FOUND, "Not found").into_response();
    }
    let session = match state.sessions.read().await.get(&query.source_id).cloned() {
        Some(session) => session,
        None => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "WebDAV source is not connected",
            )
                .into_response()
        }
    };
    let remote_url = match resolve_href(&session.base_url, &query.href)
        .and_then(|url| ensure_allowed_url(&session, &url).map(|_| url))
    {
        Ok(url) => url,
        Err(error) => return (StatusCode::BAD_REQUEST, error).into_response(),
    };
    let remote_method = if method == Method::HEAD {
        reqwest::Method::HEAD
    } else {
        reqwest::Method::GET
    };
    let mut request = session
        .client
        .request(remote_method, remote_url)
        .basic_auth(&session.username, Some(&session.password));
    if let Some(range) = request_headers.get(header::RANGE) {
        request = request.header(reqwest::header::RANGE, range.as_bytes());
    }
    let remote = match request.send().await {
        Ok(response) => response,
        Err(error) => {
            return (
                StatusCode::BAD_GATEWAY,
                format!("WebDAV stream failed: {error}"),
            )
                .into_response()
        }
    };
    let status = StatusCode::from_u16(remote.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let remote_headers = remote.headers().clone();
    let mut builder = Response::builder().status(status);
    let remote_content_type = remote_headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok());
    let content_type = match remote_content_type {
        Some(value)
            if !value.eq_ignore_ascii_case("application/octet-stream")
                && !value.eq_ignore_ascii_case("binary/octet-stream") =>
        {
            value.to_owned()
        }
        _ => mime_guess::from_path(&query.href)
            .first_or_octet_stream()
            .to_string(),
    };
    builder = builder
        .header(header::CONTENT_TYPE, content_type)
        .header(header::ACCEPT_RANGES, "bytes");
    for name in [
        header::CONTENT_LENGTH,
        header::CONTENT_RANGE,
        header::LAST_MODIFIED,
        header::ETAG,
    ] {
        if let Some(value) = remote_headers.get(&name) {
            if let Ok(value) = HeaderValue::from_bytes(value.as_bytes()) {
                builder = builder.header(name, value);
            }
        }
    }
    builder = builder.header(header::CACHE_CONTROL, "private, no-store");
    if method == Method::HEAD {
        return builder
            .body(Body::empty())
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response());
    }
    let stream = remote
        .bytes_stream()
        .map(|chunk| chunk.map_err(std::io::Error::other));
    builder
        .body(Body::from_stream(stream))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

fn default_source_name() -> String {
    "我的 WebDAV".into()
}

const fn default_true() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    const MULTISTATUS: &str = r#"<?xml version="1.0"?>
      <d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/dav/Music/</d:href><d:propstat><d:prop><d:displayname>Music</d:displayname><d:resourcetype><d:collection /></d:resourcetype></d:prop></d:propstat></d:response>
        <d:response><d:href>/dav/Music/Artist%20-%20Song.flac</d:href><d:propstat><d:prop><d:displayname>Artist - Song.flac</d:displayname><d:getcontentlength>4096</d:getcontentlength><d:getcontenttype>audio/flac</d:getcontenttype><d:getetag>abc</d:getetag></d:prop></d:propstat></d:response>
      </d:multistatus>"#;

    #[test]
    fn parses_namespaced_multistatus() {
        let entries = parse_multistatus(MULTISTATUS).expect("multistatus should parse");
        assert_eq!(entries.len(), 2);
        assert!(entries[0].is_directory);
        assert_eq!(entries[1].name, "Artist - Song.flac");
        assert_eq!(entries[1].size, 4096);
        assert_eq!(entries[1].etag.as_deref(), Some("abc"));
    }

    #[test]
    fn joins_and_encodes_relative_music_folder() {
        let base = Url::parse("https://dav.example.com/dav/").unwrap();
        let joined = join_relative_path(&base, "Music/Lossless Audio").unwrap();
        assert_eq!(
            joined.as_str(),
            "https://dav.example.com/dav/Music/Lossless%20Audio/"
        );
    }

    #[test]
    fn blocks_stream_urls_outside_authorized_root() {
        let session = WebDavSession {
            client: Client::new(),
            base_url: Url::parse("https://dav.example.com/dav/music/").unwrap(),
            username: String::new(),
            password: String::new(),
        };
        assert!(ensure_allowed_url(
            &session,
            &Url::parse("https://dav.example.com/dav/private/song.flac").unwrap()
        )
        .is_err());
        assert!(ensure_allowed_url(
            &session,
            &Url::parse("https://evil.example/song.flac").unwrap()
        )
        .is_err());
    }

    #[test]
    fn splits_artist_and_title_from_filename() {
        assert_eq!(
            title_from_filename("Air - La femme d’argent.flac"),
            ("Air".into(), "La femme d’argent".into())
        );
    }
}
