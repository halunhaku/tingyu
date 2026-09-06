import SwiftUI
import SwiftData

#if os(iOS)
public struct IOSPlaylistsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allTracks: [Track]
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]
    @Bindable var player = AudioPlayerService.shared

    @State private var showingCreatePlaylist = false
    @State private var showingRenamePlaylist = false
    @State private var playlistNameDraft = ""
    @State private var playlistPendingRename: Playlist?

    public init() {}

    public var body: some View {
        List {
            if playlists.isEmpty {
                ContentUnavailableView(
                    "还没有播放列表",
                    systemImage: "music.note.list",
                    description: Text("点右上角加号新建，或在歌曲上选择「加入播放列表」。")
                )
            } else {
                ForEach(playlists) { playlist in
                    NavigationLink {
                        playlistDetail(playlist)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                Text("\(PlaylistActions.tracks(in: playlist, from: allTracks).count) 首")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "music.note.list")
                        }
                    }
                    .contextMenu {
                        Button {
                            let tracks = PlaylistActions.tracks(in: playlist, from: allTracks)
                            player.setQueue(tracks, startingAt: 0)
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
                            PlaylistActions.delete(playlist, context: modelContext)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        PlaylistActions.delete(playlists[index], context: modelContext)
                    }
                }
            }
        }
        .avoidsBottomPlayerBar()
        .navigationTitle("播放列表")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    playlistNameDraft = ""
                    showingCreatePlaylist = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("新建播放列表", isPresented: $showingCreatePlaylist) {
            TextField("名称", text: $playlistNameDraft)
            Button("创建") {
                PlaylistActions.create(name: playlistNameDraft, context: modelContext)
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
    }

    private func playlistDetail(_ playlist: Playlist) -> some View {
        let tracks = PlaylistActions.tracks(in: playlist, from: allTracks)
        return List {
            if tracks.isEmpty {
                ContentUnavailableView("空播放列表", systemImage: "music.note")
            } else {
                ForEach(tracks) { track in
                    TrackRowView(
                        track: track,
                        isCurrent: player.currentTrack?.id == track.id,
                        playlists: playlists,
                        currentPlaylist: playlist
                    ) {
                        player.setQueue(tracks, startingAt: tracks.firstIndex(where: { $0.id == track.id }) ?? 0)
                    }
                }
            }
        }
        .avoidsBottomPlayerBar()
        .navigationTitle(playlist.name)
        .toolbar {
            if !tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        player.setQueue(tracks, startingAt: 0)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                }
            }
        }
    }
}
#endif
