import SwiftUI
import SwiftData

#if os(macOS)
struct MacOSTrackTable: View {
    let tracks: [Track]
    let playlists: [Playlist]
    var currentPlaylist: Playlist? = nil

    @Environment(\.modelContext) private var modelContext
    @Bindable private var player = AudioPlayerService.shared
    @State private var selection = Set<Track.ID>()
    @State private var matchTrack: Track?
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var newPlaylistTrack: Track?

    var body: some View {
        Table(tracks, selection: $selection) {
            TableColumn("标题") { track in
                HStack(spacing: 8) {
                    CoverArtView(data: track.coverArtData, size: 20, cornerRadius: 3)
                    Text(track.title)
                        .lineLimit(1)
                        .foregroundStyle(isCurrent(track) ? Color.accentColor : Color.primary)
                        .fontWeight(isCurrent(track) ? .semibold : .regular)
                }
            }
            .width(min: 180, ideal: 360)
            TableColumn("艺术家") { track in
                Text(track.artist)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 130, max: 180)
            TableColumn("专辑") { track in
                Text(track.album)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 130, max: 180)
            TableColumn("时间") { track in
                Text(formatDuration(track.duration))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(64)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contentMargins(.bottom, 80, for: .scrollContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("没有歌曲", systemImage: "music.note")
            }
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            contextMenu(for: tracks.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            play(ids: ids)
        }
        .sheet(item: $matchTrack) { track in
            ManualMatchSheet(track: track)
        }
        .alert("新播放列表", isPresented: $showingNewPlaylist) {
            TextField("名称", text: $newPlaylistName)
            Button("创建") {
                if let track = newPlaylistTrack {
                    PlaylistActions.create(name: newPlaylistName, context: modelContext, firstTrack: track)
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func contextMenu(for selected: [Track]) -> some View {
        if let track = selected.first {
            Button("播放") {
                play(ids: Set([track.id]))
            }
            Button("下一首播放") {
                let insertAt = min(player.currentQueueIndex + 1, player.queue.count)
                player.queue.insert(track, at: insertAt)
            }
            Button("添加到队列") {
                player.queue.append(track)
            }

            Menu("加入播放列表") {
                ForEach(playlists, id: \.id) { playlist in
                    Button(playlist.name) {
                        PlaylistActions.add(track: track, to: playlist, context: modelContext)
                    }
                }
                if !playlists.isEmpty { Divider() }
                Button("新播放列表…") {
                    newPlaylistName = ""
                    newPlaylistTrack = track
                    showingNewPlaylist = true
                }
            }

            if let currentPlaylist {
                Button("从「\(currentPlaylist.name)」移除", role: .destructive) {
                    PlaylistActions.remove(track: track, from: currentPlaylist, context: modelContext)
                }
            }

            Divider()
            Button(track.isFavorite ? "取消收藏" : "加入收藏") {
                track.isFavorite.toggle()
            }
            Divider()
            Button("重新匹配元数据…") {
                matchTrack = track
            }
        }
    }

    private func play(ids: Set<Track.ID>) {
        guard let identifier = ids.first,
              let index = tracks.firstIndex(where: { $0.id == identifier }) else { return }
        player.setQueue(tracks, startingAt: index)
        Task { await MetadataEnricher.shared.enrichTrackIfNeeded(tracks[index]) }
    }

    private func isCurrent(_ track: Track) -> Bool {
        player.currentTrack?.id == track.id
    }

    private func formatDuration(_ duration: Double) -> String {
        guard duration > 0 else { return "--:--" }
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#endif
