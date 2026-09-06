import SwiftUI
import SwiftData

#if os(macOS)
public struct MacOSContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allTracks: [Track]
    @Query private var sources: [MusicSource]
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]

    @State private var selectedSidebarItem: SidebarItem? = .library
    @State private var searchText: String = ""
    @State private var isSearchPresented = false
    @State private var showingSourceManager = false
    @State private var showingLyricsInspector = false
    @State private var showingNowPlaying = false
    @FocusState private var isSearchFocused: Bool

    @State private var showingAISettings = false
    @State private var showingCreatePlaylist = false
    @State private var showingRenamePlaylist = false
    @State private var playlistNameDraft = ""
    @State private var playlistPendingRename: Playlist?
    @State private var playlistPendingDelete: Playlist?
    @Bindable var player = AudioPlayerService.shared

    private enum SidebarItem: Hashable {
        case library
        case favorites
        case artists
        case albums
        case source(String)
        case playlist(String)
    }

    public init() {}

    public var body: some View {
        ZStack {
            NavigationSplitView {
                sidebar
            } detail: {
                detailView
                    .overlay(alignment: .bottom) {
                        if !showingNowPlaying {
                            playerBar
                                .padding(.horizontal, 24)
                                .padding(.bottom, 14)
                        }
                    }
            }
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                placement: .sidebar,
                prompt: "搜索歌曲、艺术家或专辑"
            )
            .toolbar(showingNowPlaying ? .hidden : .automatic, for: .windowToolbar)

            if showingNowPlaying {
                MacOSNowPlayingStage {
                    showingNowPlaying = false
                }
                .background(.background)
                .ignoresSafeArea()
                .overlay(alignment: .bottom) {
                    playerBar
                        .frame(maxWidth: 840)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 16)
                }
            }
        }
        .focused($isSearchFocused)
        .background {
            Button("歌词") { showingLyricsInspector.toggle() }
                .keyboardShortcut("l", modifiers: .command)
                .hidden()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tingyuFocusSearch)) { _ in
            showingNowPlaying = false
            isSearchPresented = true
        }
        .onChange(of: searchText) { _, query in
            if !query.isEmpty {
                showingNowPlaying = false
                if selectedSidebarItem != .library {
                    selectedSidebarItem = .library
                }
            }
        }
        .toolbar { windowToolbar }
        .sheet(isPresented: $showingSourceManager) {
            SourceManagerView()
                .frame(width: 480, height: 500)
        }
        .sheet(isPresented: $showingAISettings) {
            AISettingsView()
                .frame(width: 460, height: 480)
        }
        .alert("新建播放列表", isPresented: $showingCreatePlaylist) {
            TextField("名称", text: $playlistNameDraft)
            Button("创建") {
                let playlist = PlaylistActions.create(name: playlistNameDraft, context: modelContext)
                selectedSidebarItem = .playlist(playlist.id)
            }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名播放列表", isPresented: $showingRenamePlaylist) {
            TextField("名称", text: $playlistNameDraft)
            Button("保存") {
                if let playlist = playlistPendingRename {
                    PlaylistActions.rename(playlist, to: playlistNameDraft, context: modelContext)
                }
                playlistPendingRename = nil
            }
            Button("取消", role: .cancel) {
                playlistPendingRename = nil
            }
        }
        .confirmationDialog(
            "删除播放列表「\(playlistPendingDelete?.name ?? "")」？",
            isPresented: Binding(
                get: { playlistPendingDelete != nil },
                set: { if !$0 { playlistPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let playlist = playlistPendingDelete {
                    if case .playlist(let id) = selectedSidebarItem, id == playlist.id {
                        selectedSidebarItem = .library
                    }
                    PlaylistActions.delete(playlist, context: modelContext)
                }
                playlistPendingDelete = nil
            }
            Button("取消", role: .cancel) {
                playlistPendingDelete = nil
            }
        }
        .onAppear {
            AudioPlayerService.shared.configure(container: modelContext.container)
            LegacyCacheMigrator.migrateIfNeeded(modelContext: modelContext, sources: sources)
            Task {
                let corruptedTracks = allTracks.filter { $0.title == "周杰伦" && $0.filePathOrUrl.hasPrefix("quark://") }
                if corruptedTracks.count > 5, let quarkSource = sources.first(where: { $0.kind == .quark }) {
                    await repairQuarkSource(quarkSource)
                }

                for track in allTracks {
                    if track.coverArtData == nil || track.lyrics == nil || track.artist == "未知艺术家" || track.album == "未知专辑" || track.album == "夸克曲库" {
                        await MetadataEnricher.shared.enrichTrackIfNeeded(track)
                    }
                }
                try? modelContext.save()
            }
        }
    }

    private func repairQuarkSource(_ source: MusicSource) async {
        guard let folderFid = source.quarkFolderFid,
              let cookie = QuarkCookieStore.load(sourceId: source.id) else { return }

        do {
            let tracks = try await QuarkDriveClient.shared.scan(
                folderFid: folderFid,
                sourceId: source.id,
                cookie: cookie
            )
            if !tracks.isEmpty {
                LibrarySync.merge(scanned: tracks, sourceId: source.id, context: modelContext)
                source.trackCount = tracks.count
                source.syncStatus = "已同步 \(tracks.count) 首"
                try? modelContext.save()
            }
        } catch {
            print("Quark auto-repair error: \(error)")
        }
    }

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showingAISettings = true
            } label: {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.purple)
            }
            .help("AI 智能识别与洗库")

            Button {
                showingSourceManager = true
            } label: {
                Image(systemName: "folder.badge.gearshape")
            }
            .help("管理音乐来源")
        }
    }

    private var playerBar: some View {
        MacOSFloatingPlayerBar(
            showingLyrics: $showingLyricsInspector,
            showingNowPlaying: showingNowPlaying,
            onToggleNowPlaying: { showingNowPlaying.toggle() }
        )
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSidebarItem) {
            Section("我的音乐") {
                NavigationLink(value: SidebarItem.library) {
                    Label("全部曲目", systemImage: "music.note.list")
                }

                NavigationLink(value: SidebarItem.favorites) {
                    Label("我的收藏", systemImage: "heart.fill")
                }

                NavigationLink(value: SidebarItem.artists) {
                    Label("歌手", systemImage: "person.2")
                }

                NavigationLink(value: SidebarItem.albums) {
                    Label("专辑", systemImage: "square.stack")
                }
            }

            Section {
                ForEach(playlists) { playlist in
                    NavigationLink(value: SidebarItem.playlist(playlist.id)) {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                    .contextMenu {
                        Button {
                            player.setQueue(PlaylistActions.tracks(in: playlist, from: allTracks), startingAt: 0)
                        } label: {
                            Label("播放", systemImage: "play.fill")
                        }
                        Button {
                            playlistNameDraft = playlist.name
                            playlistPendingRename = playlist
                            showingRenamePlaylist = true
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            playlistPendingDelete = playlist
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack(spacing: 4) {
                    Text("播放列表")
                    Spacer()
                    Button {
                        playlistNameDraft = ""
                        showingCreatePlaylist = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("新建播放列表")
                }
            }

            Section {
                ForEach(sources) { source in
                    NavigationLink(value: SidebarItem.source(source.id)) {
                        Label(source.name, systemImage: source.kind == .webdav ? "cloud" : "folder")
                    }
                }
            } header: {
                HStack(spacing: 4) {
                    Text("音乐来源")
                    Spacer()
                    Button {
                        showingSourceManager = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("添加音乐来源")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
    }

    // MARK: - Detail View

    private var detailView: some View {
        HStack(spacing: 0) {
            Group {
                if isBrowseMode {
                    NavigationStack {
                        browseRoot
                    }
                } else {
                    MacOSTrackTable(
                        tracks: filteredTracks,
                        playlists: playlists,
                        currentPlaylist: currentPlaylist
                    )
                    .navigationTitle(currentViewTitle)
                    .navigationSubtitle("\(filteredTracks.count) 首歌曲")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showingLyricsInspector && !showingNowPlaying {
                Divider()
                ZStack {
                    FluidBackgroundView(coverData: player.currentCoverData)
                    AnimatedLyricsView(
                        lyricsText: player.currentLyrics,
                        currentTime: player.currentTime
                    ) { seekTime in
                        player.seek(to: seekTime)
                    }
                    .avoidsBottomPlayerBar()
                }
                .frame(width: 320)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var isBrowseMode: Bool {
        selectedSidebarItem == .artists || selectedSidebarItem == .albums
    }

    @ViewBuilder
    private var browseRoot: some View {
        switch selectedSidebarItem {
        case .artists:
            ArtistListView(tracks: allTracks, playlists: playlists)
        case .albums:
            AlbumGridView(tracks: allTracks, playlists: playlists)
        default:
            EmptyView()
        }
    }

    private var currentPlaylist: Playlist? {
        guard case .playlist(let id) = selectedSidebarItem else { return nil }
        return playlists.first(where: { $0.id == id })
    }

    private var currentViewTitle: String {
        switch selectedSidebarItem {
        case .library, .none:
            return "全部曲目"
        case .favorites:
            return "我的收藏"
        case .artists:
            return "歌手"
        case .albums:
            return "专辑"
        case .source(let sourceId):
            return sources.first(where: { $0.id == sourceId })?.name ?? "音乐来源"
        case .playlist:
            return currentPlaylist?.name ?? "播放列表"
        }
    }

    private var filteredTracks: [Track] {
        var result = allTracks

        switch selectedSidebarItem {
        case .favorites:
            result = result.filter { $0.isFavorite }
        case .source(let id):
            result = result.filter { $0.sourceId == id }
        case .playlist:
            if let currentPlaylist {
                result = PlaylistActions.tracks(in: currentPlaylist, from: allTracks)
            }
        default:
            break
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(query) ||
                $0.artist.lowercased().contains(query) ||
                $0.album.lowercased().contains(query)
            }
        }

        return result
    }
}
#endif
