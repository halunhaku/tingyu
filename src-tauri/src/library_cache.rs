use std::{collections::HashMap, path::Path};

use rusqlite::{params, Connection};

#[derive(Clone, Debug)]
pub struct CachedTrack {
    pub href: String,
    pub name: String,
    pub size: u64,
    pub modified: Option<String>,
    pub etag: Option<String>,
    pub content_type: Option<String>,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub year: Option<u32>,
    pub duration: f64,
    pub cover_file: Option<String>,
    pub plain_lyrics: Option<String>,
    pub synced_lyrics: Option<String>,
    pub enrichment_version: u32,
}

pub fn init(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("无法创建曲库缓存目录：{error}"))?;
    }
    let connection = open(path)?;
    connection
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS webdav_tracks (
                href TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                size INTEGER NOT NULL,
                modified TEXT,
                etag TEXT,
                content_type TEXT,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                album TEXT NOT NULL,
                year INTEGER,
                duration REAL NOT NULL DEFAULT 0,
                cover_file TEXT,
                plain_lyrics TEXT,
                synced_lyrics TEXT,
                enrichment_version INTEGER NOT NULL DEFAULT 0,
                scan_id TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS webdav_tracks_scan_id ON webdav_tracks(scan_id);",
        )
        .map_err(|error| format!("无法初始化曲库缓存：{error}"))?;
    ensure_column(&connection, "plain_lyrics", "TEXT")?;
    ensure_column(&connection, "synced_lyrics", "TEXT")?;
    ensure_column(
        &connection,
        "enrichment_version",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    Ok(())
}

pub fn load_all(path: &Path) -> Result<Vec<CachedTrack>, String> {
    let connection = open(path)?;
    let mut statement = connection
        .prepare(
            "SELECT href, name, size, modified, etag, content_type, title, artist,
                    album, year, duration, cover_file, plain_lyrics, synced_lyrics,
                    enrichment_version
             FROM webdav_tracks ORDER BY rowid",
        )
        .map_err(cache_error)?;
    let rows = statement.query_map([], row_to_track).map_err(cache_error)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(cache_error)
}

pub fn load_map(path: &Path) -> Result<HashMap<String, CachedTrack>, String> {
    Ok(load_all(path)?
        .into_iter()
        .map(|track| (track.href.clone(), track))
        .collect())
}

pub fn save_scan(path: &Path, tracks: &[CachedTrack], scan_id: &str) -> Result<usize, String> {
    let mut connection = open(path)?;
    let transaction = connection.transaction().map_err(cache_error)?;
    for track in tracks {
        transaction
            .execute(
                "INSERT INTO webdav_tracks (
                    href, name, size, modified, etag, content_type, title, artist,
                    album, year, duration, cover_file, plain_lyrics, synced_lyrics,
                    enrichment_version, scan_id
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
                 ON CONFLICT(href) DO UPDATE SET
                    name = excluded.name,
                    size = excluded.size,
                    modified = excluded.modified,
                    etag = excluded.etag,
                    content_type = excluded.content_type,
                    title = excluded.title,
                    artist = excluded.artist,
                    album = excluded.album,
                    year = excluded.year,
                    duration = excluded.duration,
                    cover_file = excluded.cover_file,
                    plain_lyrics = excluded.plain_lyrics,
                    synced_lyrics = excluded.synced_lyrics,
                    enrichment_version = excluded.enrichment_version,
                    scan_id = excluded.scan_id",
                params![
                    track.href,
                    track.name,
                    track.size as i64,
                    track.modified,
                    track.etag,
                    track.content_type,
                    track.title,
                    track.artist,
                    track.album,
                    track.year,
                    track.duration,
                    track.cover_file,
                    track.plain_lyrics,
                    track.synced_lyrics,
                    track.enrichment_version,
                    scan_id,
                ],
            )
            .map_err(cache_error)?;
    }
    let removed = transaction
        .execute("DELETE FROM webdav_tracks WHERE scan_id != ?1", [scan_id])
        .map_err(cache_error)?;
    transaction.commit().map_err(cache_error)?;
    Ok(removed)
}

pub fn clear_all(path: &Path) -> Result<(), String> {
    let connection = open(path)?;
    connection
        .execute("DELETE FROM webdav_tracks", [])
        .map_err(cache_error)?;
    Ok(())
}

pub fn update_enrichment(path: &Path, track: &CachedTrack) -> Result<(), String> {
    let connection = open(path)?;
    connection
        .execute(
            "UPDATE webdav_tracks
             SET cover_file = ?1, plain_lyrics = ?2, synced_lyrics = ?3,
                 enrichment_version = ?4
             WHERE href = ?5",
            params![
                track.cover_file,
                track.plain_lyrics,
                track.synced_lyrics,
                track.enrichment_version,
                track.href,
            ],
        )
        .map_err(cache_error)?;
    Ok(())
}

pub fn update_duration(path: &Path, href: &str, duration: f64) -> Result<(), String> {
    let connection = open(path)?;
    connection
        .execute(
            "UPDATE webdav_tracks SET duration = ?1 WHERE href = ?2",
            params![duration, href],
        )
        .map_err(cache_error)?;
    Ok(())
}

fn ensure_column(connection: &Connection, name: &str, definition: &str) -> Result<(), String> {
    let mut statement = connection
        .prepare("PRAGMA table_info(webdav_tracks)")
        .map_err(cache_error)?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(cache_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(cache_error)?;
    drop(statement);
    if !columns.iter().any(|column| column == name) {
        connection
            .execute(
                &format!("ALTER TABLE webdav_tracks ADD COLUMN {name} {definition}"),
                [],
            )
            .map_err(cache_error)?;
    }
    Ok(())
}

fn open(path: &Path) -> Result<Connection, String> {
    Connection::open(path).map_err(cache_error)
}

fn row_to_track(row: &rusqlite::Row<'_>) -> rusqlite::Result<CachedTrack> {
    Ok(CachedTrack {
        href: row.get(0)?,
        name: row.get(1)?,
        size: row.get::<_, i64>(2)?.max(0) as u64,
        modified: row.get(3)?,
        etag: row.get(4)?,
        content_type: row.get(5)?,
        title: row.get(6)?,
        artist: row.get(7)?,
        album: row.get(8)?,
        year: row.get(9)?,
        duration: row.get(10)?,
        cover_file: row.get(11)?,
        plain_lyrics: row.get(12)?,
        synced_lyrics: row.get(13)?,
        enrichment_version: row.get::<_, i64>(14)?.max(0) as u32,
    })
}

fn cache_error(error: rusqlite::Error) -> String {
    format!("曲库缓存操作失败：{error}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn migrates_existing_library_with_enrichment_columns() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("tingyu-library-{unique}.sqlite3"));
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE webdav_tracks (
                    href TEXT PRIMARY KEY, name TEXT NOT NULL, size INTEGER NOT NULL,
                    title TEXT NOT NULL, artist TEXT NOT NULL, album TEXT NOT NULL,
                    duration REAL NOT NULL DEFAULT 0, scan_id TEXT NOT NULL DEFAULT ''
                );",
            )
            .unwrap();
        drop(connection);

        init(&path).unwrap();
        let connection = Connection::open(&path).unwrap();
        let mut statement = connection
            .prepare("PRAGMA table_info(webdav_tracks)")
            .unwrap();
        let columns = statement
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert!(columns.iter().any(|column| column == "plain_lyrics"));
        assert!(columns.iter().any(|column| column == "synced_lyrics"));
        assert!(columns.iter().any(|column| column == "enrichment_version"));
        drop(statement);
        drop(connection);
        let _ = std::fs::remove_file(path);
    }
}
