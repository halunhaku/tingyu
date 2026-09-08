import SwiftUI
import SwiftData

#if os(macOS)
struct MacOSTrackTable: View {
    let tracks: [Track]
    let playlists: [Playlist]
    var currentPlaylist: Playlist? = nil

    @Environment(\.modelContext) private var modelContext
    @Bindable private var player = AudioPlayerService.shared
    @State private var selection = Set<String>()
    @State private var matchTrack: Track?
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var newPlaylistTrack: Track?
    @State private var hoveredTrackId: String?
    var body: some View {
        Table(tracks, selection: $selection) {
            TableColumn("") { track in
                Button {
                    track.isFavorite.toggle()
                } label: {
                    Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 13))
                        .foregroundStyle(track.isFavorite ? Color.appleMusicRed : Color.secondary.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
            .width(24)

            TableColumn("名称") { track in
                let isCurrent = isCurrent(track)
                let isHovered = hoveredTrackId == track.id
                HStack(spacing: 12) {
                    Button {
                        if isCurrent && player.isPlaying {
                            player.togglePlayPause()
                        } else {
                            play(ids: Set([track.id]))
                        }
                    } label: {
                        ZStack {
                            CoverArtView(data: track.coverArtData, size: 34, cornerRadius: 4)
                            if isCurrent && player.isPlaying {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.black.opacity(0.45))
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.white)
                            } else if isHovered {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.black.opacity(0.4))
                                Image(systemName: "play.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.white)
                            }
                        }
                        .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .help(isCurrent && player.isPlaying ? "暂停" : "播放")

                    Text(track.title)
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? Color.appleMusicRed : Color.primary)
                        .fontWeight(isCurrent ? .semibold : .regular)
                }
                .contentShape(Rectangle())
                .onHover { hovering in
                    hoveredTrackId = hovering ? track.id : nil
                }
            }
            .width(min: 200, ideal: 340)

            TableColumn("艺人") { track in
                Text(track.artist)
                    .foregroundStyle(isCurrent(track) ? Color.appleMusicRed.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 160, max: 220)

            TableColumn("专辑") { track in
                Text(track.album)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 160, max: 220)

            TableColumn("时间") { track in
                Text(formatDuration(track.duration))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(64)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contentMargins(.bottom, 110, for: .scrollContent)
        .contentMargins(.top, 16, for: .scrollIndicators)
        .contentMargins(.bottom, 84, for: .scrollIndicators)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("没有歌曲", systemImage: "music.note")
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
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
        .onChange(of: selection) { _, _ in
            NSApp.keyWindow?.makeFirstResponder(nil)
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
            Divider()
            Button("在专辑中查看") {
                NotificationCenter.default.post(name: .tingyuSearchQuery, object: track.album)
            }
            Button("在艺人中查看") {
                NotificationCenter.default.post(name: .tingyuSearchQuery, object: track.artist)
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

    private func play(ids: Set<String>) {
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
