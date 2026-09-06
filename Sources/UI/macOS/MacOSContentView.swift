import SwiftUI
import SwiftData

#if os(macOS)
public struct MacOSContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allTracks: [Track]
    @Query private var sources: [MusicSource]

    @State private var selectedSidebarItem: SidebarItem? = .library
    @State private var searchText: String = ""
    @State private var showingSourceManager = false
    @State private var showingLyricsInspector = false
    @FocusState private var isSearchFocused: Bool

    @State private var showingAISettings = false
    @Bindable var player = AudioPlayerService.shared

    private enum SidebarItem: Hashable {
        case library
        case favorites
        case source(String)
    }

    public init() {}

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索歌曲、艺术家或专辑 (⌘K)")
        .focused($isSearchFocused)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingLyricsInspector.toggle()
                } label: {
                    Image(systemName: "quote.bubble")
                        .foregroundStyle(showingLyricsInspector ? Color.accentColor : Color.secondary)
                }
                .help("歌词面板 (⌘L)")

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
        .sheet(isPresented: $showingSourceManager) {
            SourceManagerView()
                .frame(minWidth: 500, minHeight: 400)
        }
        .sheet(isPresented: $showingAISettings) {
            AISettingsView()
        }
        .safeAreaInset(edge: .bottom) {
            MacOSPlayerBar(showingLyrics: $showingLyricsInspector)
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
                let sourceId = source.id
                let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.sourceId == sourceId })
                if let existing = try? modelContext.fetch(descriptor) {
                    for old in existing {
                        modelContext.delete(old)
                    }
                }
                for track in tracks {
                    modelContext.insert(track)
                }
                source.trackCount = tracks.count
                source.syncStatus = "已同步 \(tracks.count) 首"
                try? modelContext.save()
            }
        } catch {
            print("Quark auto-repair error: \(error)")
        }
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
            }

            Section {
                ForEach(sources) { source in
                    NavigationLink(value: SidebarItem.source(source.id)) {
                        Label(source.name, systemImage: source.kind == .webdav ? "cloud" : "folder")
                    }
                }
            } header: {
                HStack {
                    Text("音乐来源")
                    Spacer()
                    Button {
                        showingSourceManager = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
    }

    // MARK: - Detail View

    private var detailView: some View {
        HStack(spacing: 0) {
            // Track List
            VStack(spacing: 0) {
                headerView

                List {
                    ForEach(filteredTracks) { track in
                        TrackRowView(
                            track: track,
                            isCurrent: player.currentTrack?.id == track.id
                        ) {
                            player.setQueue(filteredTracks, startingAt: filteredTracks.firstIndex(where: { $0.id == track.id }) ?? 0)
                            Task {
                                await MetadataEnricher.shared.enrichTrackIfNeeded(track)
                            }
                        }
                    }

                    // Bottom padding spacer so the last song scrolls completely above the floating player bar
                    Color.clear
                        .frame(height: 76)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
            }
            .frame(maxWidth: .infinity)

            // Collapsible Lyrics Inspector
            if showingLyricsInspector {
                Divider()
                ZStack {
                    FluidBackgroundView(coverData: player.currentCoverData)
                    AnimatedLyricsView(
                        lyricsText: player.currentLyrics,
                        currentTime: player.currentTime
                    ) { seekTime in
                        player.seek(to: seekTime)
                    }
                }
                .frame(width: 320)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(currentViewTitle)
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("\(filteredTracks.count) 首歌曲")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var currentViewTitle: String {
        switch selectedSidebarItem {
        case .library, .none:
            return "全部曲目"
        case .favorites:
            return "我的收藏"
        case .source(let sourceId):
            return sources.first(where: { $0.id == sourceId })?.name ?? "音乐来源"
        }
    }

    private var filteredTracks: [Track] {
        var result = allTracks

        switch selectedSidebarItem {
        case .favorites:
            result = result.filter { $0.isFavorite }
        case .source(let id):
            result = result.filter { $0.sourceId == id }
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
