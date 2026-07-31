use std::path::Path;

use keyring::{Entry, Error as KeyringError};
use serde::{Deserialize, Serialize};

const KEYCHAIN_SERVICE: &str = "com.halunhaku.tingyu.webdav";
const KEYCHAIN_ACCOUNT: &str = "default";

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
    keychain_entry()?
        .set_password(password)
        .map_err(|error| format!("无法写入系统 Keychain：{error}"))?;
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
    let password = match keychain_entry()?.get_password() {
        Ok(password) => password,
        Err(KeyringError::NoEntry) => return Ok(None),
        Err(error) => return Err(format!("无法读取系统 Keychain：{error}")),
    };
    Ok(Some((connection, password)))
}

pub fn forget(path: &Path) -> Result<(), String> {
    match keychain_entry()?.delete_credential() {
        Ok(()) | Err(KeyringError::NoEntry) => {}
        Err(error) => return Err(format!("无法删除系统 Keychain 凭据：{error}")),
    }
    if path.exists() {
        std::fs::remove_file(path).map_err(|error| format!("无法删除连接配置：{error}"))?;
    }
    Ok(())
}

fn default_source_name() -> String {
    "我的 WebDAV".into()
}

fn keychain_entry() -> Result<Entry, String> {
    Entry::new(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)
        .map_err(|error| format!("无法访问系统 Keychain：{error}"))
}
