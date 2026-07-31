use serde::{Deserialize, Serialize};
#[cfg(target_os = "android")]
use tauri::Manager;
use tauri::{
    plugin::{Builder, TauriPlugin},
    AppHandle, Runtime,
};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AndroidPlaybackState {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub artwork_url: Option<String>,
    pub duration_ms: u64,
    pub position_ms: u64,
    pub playing: bool,
}

#[cfg(target_os = "android")]
#[derive(Clone)]
struct AndroidMediaSession<R: Runtime>(tauri::plugin::PluginHandle<R>);

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("android-media-session")
        .setup(|app, api| {
            #[cfg(target_os = "android")]
            {
                let handle =
                    api.register_android_plugin("com.halunhaku.tingyu", "MediaSessionPlugin")?;
                app.manage(AndroidMediaSession(handle));
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
pub fn android_media_update(app: AppHandle, state: AndroidPlaybackState) -> Result<(), String> {
    #[cfg(target_os = "android")]
    {
        app.state::<AndroidMediaSession<tauri::Wry>>()
            .0
            .run_mobile_plugin("updatePlayback", state)
            .map_err(|error| format!("无法更新 Android 媒体会话：{error}"))
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = (app, state);
        Ok(())
    }
}

#[tauri::command]
pub fn android_media_clear(app: AppHandle) -> Result<(), String> {
    #[cfg(target_os = "android")]
    {
        app.state::<AndroidMediaSession<tauri::Wry>>()
            .0
            .run_mobile_plugin("clear", ())
            .map_err(|error| format!("无法关闭 Android 媒体会话：{error}"))
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = app;
        Ok(())
    }
}
