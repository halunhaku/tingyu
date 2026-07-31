fn main() {
    let media_session_plugin = tauri_build::InlinedPlugin::new()
        .commands(&[
            "register_listener",
            "registerListener",
            "remove_listener",
            "removeListener",
            "check_permissions",
            "request_permissions",
        ])
        .default_permission(tauri_build::DefaultPermissionRule::AllowAllCommands);

    tauri_build::try_build(
        tauri_build::Attributes::new().plugin("android-media-session", media_session_plugin),
    )
    .expect("failed to build Tauri application");
}
