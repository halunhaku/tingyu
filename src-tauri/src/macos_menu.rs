use tauri::{
    menu::{AboutMetadataBuilder, Menu, MenuBuilder, MenuItemBuilder, SubmenuBuilder},
    AppHandle, Runtime,
};

pub const MENU_EVENT: &str = "macos-menu-action";

pub fn build<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<Menu<R>> {
    let about = AboutMetadataBuilder::new()
        .name(Some("听屿"))
        .version(Some(env!("CARGO_PKG_VERSION")))
        .copyright(Some("© 2026 听屿"))
        .credits(Some("连接本地文件夹与 WebDAV 的私人音乐播放器。"))
        .icon(app.default_window_icon().cloned())
        .build();

    let source_settings = MenuItemBuilder::with_id("sources.manage", "音乐源设置…")
        .accelerator("CmdOrCtrl+Comma")
        .build(app)?;
    let app_menu = SubmenuBuilder::new(app, "听屿")
        .about_with_text("关于听屿", Some(about))
        .separator()
        .item(&source_settings)
        .separator()
        .services_with_text("服务")
        .separator()
        .hide_with_text("隐藏听屿")
        .hide_others_with_text("隐藏其他")
        .show_all_with_text("全部显示")
        .separator()
        .quit_with_text("退出听屿")
        .build()?;

    let refresh_library = MenuItemBuilder::with_id("library.refresh", "刷新曲库")
        .accelerator("CmdOrCtrl+R")
        .build(app)?;
    let file_menu = SubmenuBuilder::new(app, "文件")
        .item(&refresh_library)
        .separator()
        .close_window_with_text("关闭窗口")
        .build()?;

    let edit_menu = SubmenuBuilder::new(app, "编辑")
        .undo_with_text("撤销")
        .redo_with_text("重做")
        .separator()
        .cut_with_text("剪切")
        .copy_with_text("拷贝")
        .paste_with_text("粘贴")
        .select_all_with_text("全选")
        .build()?;

    let play_pause = MenuItemBuilder::with_id("playback.toggle", "播放 / 暂停")
        .accelerator("CmdOrCtrl+Shift+P")
        .build(app)?;
    let previous = MenuItemBuilder::with_id("playback.previous", "上一首").build(app)?;
    let next = MenuItemBuilder::with_id("playback.next", "下一首").build(app)?;
    let shuffle = MenuItemBuilder::with_id("playback.shuffle", "切换随机/顺序播放")
        .accelerator("CmdOrCtrl+Shift+S")
        .build(app)?;
    let lyrics = MenuItemBuilder::with_id("lyrics.toggle", "显示歌词")
        .accelerator("CmdOrCtrl+L")
        .build(app)?;
    let playback_menu = SubmenuBuilder::new(app, "播放控制")
        .item(&play_pause)
        .separator()
        .item(&previous)
        .item(&next)
        .item(&shuffle)
        .separator()
        .item(&lyrics)
        .build()?;

    let show_library = MenuItemBuilder::with_id("view.library", "曲库")
        .accelerator("CmdOrCtrl+1")
        .build(app)?;
    let show_favorites = MenuItemBuilder::with_id("view.favorites", "我喜欢的")
        .accelerator("CmdOrCtrl+2")
        .build(app)?;
    let focus_search = MenuItemBuilder::with_id("view.search", "搜索曲库")
        .accelerator("CmdOrCtrl+F")
        .build(app)?;
    let view_menu = SubmenuBuilder::new(app, "显示")
        .item(&show_library)
        .item(&show_favorites)
        .separator()
        .item(&focus_search)
        .separator()
        .fullscreen_with_text("进入全屏幕")
        .build()?;

    let window_menu = SubmenuBuilder::new(app, "窗口")
        .minimize_with_text("最小化")
        .maximize_with_text("缩放")
        .separator()
        .bring_all_to_front_with_text("前置全部窗口")
        .build()?;

    MenuBuilder::new(app)
        .items(&[
            &app_menu,
            &file_menu,
            &edit_menu,
            &playback_menu,
            &view_menu,
            &window_menu,
        ])
        .build()
}
