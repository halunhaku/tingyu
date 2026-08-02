use serde::{Deserialize, Serialize};
#[cfg(target_os = "android")]
use tauri::Manager;
use tauri::{
    plugin::{Builder, TauriPlugin},
    AppHandle, Runtime,
};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AndroidFolder {
    pub uri: String,
    pub name: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AndroidFile {
    pub uri: String,
    pub name: String,
    pub album: String,
    pub size: u64,
    pub modified: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AndroidScanResult {
    pub name: String,
    pub files: Vec<AndroidFile>,
}

#[cfg(target_os = "android")]
#[derive(Clone)]
struct AndroidLocalFolder<R: Runtime>(tauri::plugin::PluginHandle<R>);

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("android-local-folder")
        .setup(|app, api| {
            #[cfg(target_os = "android")]
            {
                let handle =
                    api.register_android_plugin("com.halunhaku.tingyu", "LocalFolderPlugin")?;
                app.manage(AndroidLocalFolder(handle));
            }
            #[cfg(not(target_os = "android"))]
            {
                let _ = (app, api);
            }
            Ok(())
        })
        .build()
}

#[tauri::command]
pub async fn android_local_folder_pick(app: AppHandle) -> Result<Option<AndroidFolder>, String> {
    tauri::async_runtime::spawn_blocking(move || pick_folder(&app))
        .await
        .map_err(|error| format!("Android 文件夹选择任务失败：{error}"))?
}

fn pick_folder(app: &AppHandle) -> Result<Option<AndroidFolder>, String> {
    #[cfg(target_os = "android")]
    {
        app.state::<AndroidLocalFolder<tauri::Wry>>()
            .0
            .run_mobile_plugin("pickFolder", ())
            .map_err(|error| format!("无法打开 Android 文件夹选择器：{error}"))
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = app;
        Err("Android 文件夹选择器仅在 Android 端可用".into())
    }
}

pub fn scan(app: &AppHandle, uri: &str) -> Result<AndroidScanResult, String> {
    #[cfg(target_os = "android")]
    {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Payload<'a> {
            root_uri: &'a str,
        }

        app.state::<AndroidLocalFolder<tauri::Wry>>()
            .0
            .run_mobile_plugin("scanFolder", Payload { root_uri: uri })
            .map_err(|error| format!("无法扫描 Android 本地曲库：{error}"))
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = (app, uri);
        Err("Android 本地曲库仅在 Android 端可用".into())
    }
}

pub fn release(app: &AppHandle, uri: &str) -> Result<(), String> {
    #[cfg(target_os = "android")]
    {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Payload<'a> {
            root_uri: &'a str,
        }

        app.state::<AndroidLocalFolder<tauri::Wry>>()
            .0
            .run_mobile_plugin("releaseFolder", Payload { root_uri: uri })
            .map_err(|error| format!("无法释放 Android 文件夹访问权限：{error}"))
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = (app, uri);
        Ok(())
    }
}
