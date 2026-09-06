import SwiftUI
import SwiftData

#if os(iOS)
public struct IOSContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allTracks: [Track]
    @Query private var sources: [MusicSource]
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]

    @State private var selectedTab: Int = 0
    @State private var searchText: String = ""
    @State private var libraryFilter: LibraryFilter = .all
    @State private var showingNowPlayingSheet = false
    @State private var showingSourceManager = false
    @State private var showingAISettings = false

    @Bindable var player = AudioPlayerService.shared

    private enum LibraryFilter: Hashable {
        case all
        case source(String)
    }

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    libraryList
                }
                .tabItem {
                    Label("曲库", systemImage: "square.stack")
                }
                .tag(0)

                NavigationStack {
                    List {
                        ForEach(favoriteTracks) { track in
                            trackRow(track, queue: favoriteTracks)
                        }
                    }
                    .listStyle(.plain)
                    .navigationTitle("收藏")
                    .overlay {
                        if favoriteTracks.isEmpty {
                            ContentUnavailableView("还没有收藏", systemImage: "heart")
                        }
                    }
                    .safeAreaPadding(.bottom, 72)
                }
                .tabItem {
                    Label("收藏", systemImage: "heart.fill")
                }
                .tag(1)

                NavigationStack {
                    IOSPlaylistsView()
                }
                .tabItem {
                    Label("歌单", systemImage: "music.note.list")
                }
                .tag(2)

                NavigationStack {
                    SourceManagerView()
                }
                .tabItem {
                    Label("音乐源", systemImage: "server.rack")
                }
                .tag(3)
            }

            IOSMiniPlayer {
                showingNowPlayingSheet = true
            }
        }
        .sheet(isPresented: $showingNowPlayingSheet) {
            IOSNowPlayingSheet()
        }
        .sheet(isPresented: $showingSourceManager) {
            SourceManagerView()
        }
        .sheet(isPresented: $showingAISettings) {
            AISettingsView()
        }
        .onAppear {
            AudioPlayerService.shared.configure(container: modelContext.container)
        }
    }

    private var libraryList: some View {
        List {
            ForEach(libraryTracks) { track in
                trackRow(track, queue: libraryTracks)
            }
        }
        .listStyle(.plain)
        .navigationTitle(libraryTitle)
        .searchable(text: $searchText, prompt: "搜索歌曲、艺术家或专辑")
        .overlay {
            if libraryTracks.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "曲库是空的" : "没有匹配的歌曲",
                    systemImage: "music.note"
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("全部曲目") {
                        libraryFilter = .all
                    }
                    if !sources.isEmpty {
                        Divider()
                        ForEach(sources) { source in
                            Button(source.name) {
                                libraryFilter = .source(source.id)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }

                Button {
                    showingAISettings = true
                } label: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.purple)
                }

                Button {
                    showingSourceManager = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
            }
        }
        .safeAreaPadding(.bottom, 72)
    }

    private func trackRow(_ track: Track, queue: [Track]) -> some View {
        TrackRowView(
            track: track,
            isCurrent: player.currentTrack?.id == track.id,
            playlists: playlists
        ) {
            player.setQueue(queue, startingAt: queue.firstIndex(where: { $0.id == track.id }) ?? 0)
            Task {
                await MetadataEnricher.shared.enrichTrackIfNeeded(track)
            }
        }
    }

    private var libraryTitle: String {
        switch libraryFilter {
        case .all:
            return "曲库"
        case .source(let id):
            return sources.first(where: { $0.id == id })?.name ?? "曲库"
        }
    }

    private var libraryTracks: [Track] {
        var result = allTracks
        if case .source(let id) = libraryFilter {
            result = result.filter { $0.sourceId == id }
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

    private var favoriteTracks: [Track] {
        allTracks.filter(\.isFavorite)
    }
}
#endif
