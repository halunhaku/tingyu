mod android_local;
mod android_media;
mod credentials;
mod library_cache;
mod local_library;
#[cfg(target_os = "macos")]
mod macos_menu;
mod metadata;
mod scraper;
mod webdav;

use std::net::TcpListener as StdTcpListener;
#[cfg(target_os = "macos")]
use tauri::Emitter;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(android_local::init())
        .plugin(android_media::init())
        .setup(|app| {
            #[cfg(target_os = "macos")]
            {
                app.set_menu(macos_menu::build(app.handle())?)?;
                app.on_menu_event(|app, event| {
                    let _ = app.emit(macos_menu::MENU_EVENT, event.id().as_ref());
                });
            }

            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }

            let listener = StdTcpListener::bind("127.0.0.1:0")?;
            listener.set_nonblocking(true)?;
            let port = listener.local_addr()?.port();
            let app_data = app.path().app_data_dir()?;
            let app_cache = app.path().app_cache_dir()?;
            let webdav_state = webdav::create_state(
                app.handle().clone(),
                port,
                app_data.join("library.sqlite3"),
                app_cache.join("covers"),
                app_data.join("webdav-connection.json"),
                app_data.join("local-folder.json"),
            )
            .map_err(std::io::Error::other)?;
            app.manage(webdav_state.clone());

            let enrichment_state = webdav_state.clone();
            tauri::async_runtime::spawn(async move {
                webdav::enrich_cached_library(enrichment_state).await;
            });

            tauri::async_runtime::spawn(async move {
                let listener = tokio::net::TcpListener::from_std(listener)
                    .expect("failed to start the local audio proxy");
                if let Err(error) = axum::serve(listener, webdav::proxy_router(webdav_state)).await
                {
                    log::error!("local audio proxy stopped: {error}");
                }
            });
            Ok(())
        })
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            android_local::android_local_folder_pick,
            android_media::android_media_update,
            android_media::android_media_clear,
            webdav::webdav_connect,
            webdav::webdav_restore,
            webdav::webdav_forget,
            webdav::webdav_cached_library,
            webdav::webdav_update_duration,
            webdav::webdav_scrape_track,
            webdav::webdav_scan,
            local_library::local_library_scan,
            local_library::local_library_scan_android,
            local_library::local_library_restore,
            local_library::local_library_scrape_track,
            local_library::local_library_forget,
        ])
        .plugin(tauri_plugin_fs::init())
        .run(tauri::generate_context!())
        .expect("error while running Tauri application");
}
