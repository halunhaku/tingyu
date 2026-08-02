use std::path::Path;

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux"
))]
use keyring::{Entry, Error as KeyringError};
use serde::{Deserialize, Serialize};

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux"
))]
const CREDENTIAL_SERVICE: &str = "com.halunhaku.tingyu.webdav";
#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux"
))]
const LEGACY_CREDENTIAL_ACCOUNT: &str = "default";

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedConnection {
    #[serde(default = "default_source_name")]
    pub name: String,
    pub base_url: String,
    pub username: String,
    pub folder: String,
}

pub fn save(path: &Path, connection: &SavedConnection, password: &str) -> Result<(), String> {
    save_password(path, password)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("无法创建连接配置目录：{error}"))?;
    }
    let json = serde_json::to_vec_pretty(connection)
        .map_err(|error| format!("无法序列化连接配置：{error}"))?;
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, json).map_err(|error| format!("无法写入连接配置：{error}"))?;
    std::fs::rename(&temporary, path).map_err(|error| format!("无法保存连接配置：{error}"))?;
    Ok(())
}

pub fn load_saved(path: &Path) -> Result<Option<SavedConnection>, String> {
    if !path.exists() {
        return Ok(None);
    }
    let bytes = std::fs::read(path).map_err(|error| format!("无法读取连接配置：{error}"))?;
    let connection: SavedConnection =
        serde_json::from_slice(&bytes).map_err(|error| format!("连接配置已损坏：{error}"))?;
    Ok(Some(connection))
}

pub fn load(path: &Path) -> Result<Option<(SavedConnection, String)>, String> {
    let Some(connection) = load_saved(path)? else {
        return Ok(None);
    };
    let Some(password) = load_password(path)? else {
        return Ok(None);
    };
    Ok(Some((connection, password)))
}

pub fn forget(path: &Path) -> Result<(), String> {
    let password = load_password(path)?;
    forget_password(path)?;
    if path.exists() {
        if let Err(error) = std::fs::remove_file(path) {
            let rollback = password
                .as_deref()
                .map_or(Ok(()), |password| save_password(path, password));
            return match rollback {
                Ok(()) => Err(format!("无法删除连接配置：{error}")),
                Err(rollback_error) => Err(format!(
                    "无法删除连接配置：{error}；凭据回滚失败：{rollback_error}"
                )),
            };
        }
    }
    Ok(())
}

fn default_source_name() -> String {
    "我的 WebDAV".into()
}

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux"
))]
fn credential_account(path: &Path) -> String {
    match path.file_name().and_then(|value| value.to_str()) {
        Some("webdav-connection.json") => LEGACY_CREDENTIAL_ACCOUNT.into(),
        _ => path
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or(LEGACY_CREDENTIAL_ACCOUNT)
            .to_string(),
    }
}

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux"
))]
fn credential_entry(path: &Path) -> Result<Entry, String> {
    Entry::new(CREDENTIAL_SERVICE, &credential_account(path))
        .map_err(|error| format!("无法访问系统凭据库：{error}"))
}

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux"
))]
fn save_password(path: &Path, password: &str) -> Result<(), String> {
    credential_entry(path)?
        .set_password(password)
        .map_err(|error| format!("无法写入系统凭据库：{error}"))
}

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux"
))]
fn load_password(path: &Path) -> Result<Option<String>, String> {
    match credential_entry(path)?.get_password() {
        Ok(password) => Ok(Some(password)),
        Err(KeyringError::NoEntry) => migrate_legacy_password(path),
        Err(error) => Err(format!("无法读取系统凭据库：{error}")),
    }
}

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux"
))]
fn forget_password(path: &Path) -> Result<(), String> {
    match credential_entry(path)?.delete_credential() {
        Ok(()) | Err(KeyringError::NoEntry) => {}
        Err(error) => return Err(format!("无法删除系统凭据库凭据：{error}")),
    }
    match std::fs::remove_file(password_path(path)) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("无法删除旧版应用凭据：{error}")),
    }
}

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux"
))]
fn migrate_legacy_password(path: &Path) -> Result<Option<String>, String> {
    let legacy_path = password_path(path);
    let password = match std::fs::read_to_string(&legacy_path) {
        Ok(password) => password,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("无法读取旧版应用凭据：{error}")),
    };
    save_password(path, &password)?;
    if let Err(error) = std::fs::remove_file(&legacy_path) {
        let _ = credential_entry(path)?.delete_credential();
        return Err(format!("无法完成旧版凭据迁移：{error}"));
    }
    Ok(Some(password))
}

fn password_path(path: &Path) -> std::path::PathBuf {
    path.with_extension("credential")
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux"
)))]
fn save_password(path: &Path, password: &str) -> Result<(), String> {
    use std::io::Write;

    let path = password_path(path);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| format!("无法创建凭据目录：{error}"))?;
    }
    let temporary = path.with_extension("credential.tmp");
    let mut options = std::fs::OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&temporary)
        .map_err(|error| format!("无法写入应用私有凭据：{error}"))?;
    file.write_all(password.as_bytes())
        .map_err(|error| format!("无法写入应用私有凭据：{error}"))?;
    file.sync_all()
        .map_err(|error| format!("无法保存应用私有凭据：{error}"))?;
    std::fs::rename(&temporary, &path).map_err(|error| format!("无法保存应用私有凭据：{error}"))
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux"
)))]
fn load_password(path: &Path) -> Result<Option<String>, String> {
    match std::fs::read_to_string(password_path(path)) {
        Ok(password) => Ok(Some(password)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("无法读取应用私有凭据：{error}")),
    }
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux"
)))]
fn forget_password(path: &Path) -> Result<(), String> {
    let path = password_path(path);
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("无法删除应用私有凭据：{error}")),
    }
}
