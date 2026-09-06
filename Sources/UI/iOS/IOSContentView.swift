import SwiftUI
import SwiftData

#if os(iOS)
public struct IOSContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allTracks: [Track]
    @Query private var sources: [MusicSource]

    @State private var selectedTab: Int = 0
    @State private var searchText: String = ""
    @State private var showingNowPlayingSheet = false
    @State private var showingSourceManager = false

    @Bindable var player = AudioPlayerService.shared

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                // Tab 1: Library
                NavigationStack {
                    List {
                        ForEach(allTracks) { track in
                            TrackRowView(
                                track: track,
                                isCurrent: player.currentTrack?.id == track.id
                            ) {
                                player.setQueue(allTracks, startingAt: allTracks.firstIndex(where: { $0.id == track.id }) ?? 0)
                                Task {
                                    await MetadataEnricher.shared.enrichTrackIfNeeded(track)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .navigationTitle("曲库")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showingSourceManager = true
                            } label: {
                                Image(systemName: "folder.badge.gearshape")
                            }
                        }
                    }
                }
                .tabItem {
                    Label("曲库", systemImage: "music.note.list")
                }
                .tag(0)

                // Tab 2: Favorites
                NavigationStack {
                    List {
                        let favorites = allTracks.filter { $0.isFavorite }
                        ForEach(favorites) { track in
                            TrackRowView(
                                track: track,
                                isCurrent: player.currentTrack?.id == track.id
                            ) {
                                player.setQueue(favorites, startingAt: favorites.firstIndex(where: { $0.id == track.id }) ?? 0)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .navigationTitle("收藏")
                }
                .tabItem {
                    Label("收藏", systemImage: "heart.fill")
                }
                .tag(1)

                // Tab 3: Sources
                NavigationStack {
                    SourceManagerView()
                }
                .tabItem {
                    Label("音乐源", systemImage: "server.rack")
                }
                .tag(2)

                // Tab 4: Search
                NavigationStack {
                    List {
                        ForEach(searchResults) { track in
                            TrackRowView(
                                track: track,
                                isCurrent: player.currentTrack?.id == track.id
                            ) {
                                player.setQueue(searchResults, startingAt: searchResults.firstIndex(where: { $0.id == track.id }) ?? 0)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .navigationTitle("搜索")
                    .searchable(text: $searchText, prompt: "搜索歌曲、艺术家或专辑")
                }
                .tabItem {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .tag(3)
            }

            // Floating MiniPlayer
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
        .onAppear {
            AudioPlayerService.shared.configure(container: modelContext.container)
        }
    }

    private var searchResults: [Track] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        return allTracks.filter {
            $0.title.lowercased().contains(q) ||
            $0.artist.lowercased().contains(q) ||
            $0.album.lowercased().contains(q)
        }
    }
}
#endif
