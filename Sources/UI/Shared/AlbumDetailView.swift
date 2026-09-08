import SwiftUI
import SwiftData

struct AlbumDetailView: View {
    let album: AlbumSummary
    let playlists: [Playlist]
    @Environment(\.modelContext) private var modelContext
    @Bindable private var player = AudioPlayerService.shared
    @State private var hoveredTrackId: String?

    private var totalDuration: Double {
        album.tracks.reduce(0) { $0 + $1.duration }
    }

    private var durationString: String {
        let mins = Int(totalDuration / 60)
        return mins > 0 ? "\(mins) 分钟" : "\(Int(totalDuration)) 秒"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // MARK: - Album Header
                HStack(alignment: .bottom, spacing: 24) {
                    CoverArtView(
                        data: album.coverArtData,
                        size: 180,
                        cornerRadius: 12
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(album.album)
                            .font(.system(size: 26, weight: .bold))
                            .lineLimit(2)

                        Button {
                            NotificationCenter.default.post(name: .tingyuSearchQuery, object: album.artist)
                        } label: {
                            Text(album.artist)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.appleMusicRed)
                        }
                        .buttonStyle(.plain)
                        .help("在艺人中查看")

                        HStack(spacing: 6) {
                            if let year = album.year {
                                Text("\(String(year))年")
                                Text("·")
                            }
                            Text("\(album.tracks.count) 首歌曲")
                            Text("·")
                            Text(durationString)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                        // Play & Shuffle Buttons
                        HStack(spacing: 12) {
                            Button {
                                player.setQueue(album.tracks, startingAt: 0)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("播放")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 8)
                                .background(Color.appleMusicRed)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)

                            Button {
                                player.setQueue(album.tracks.shuffled(), startingAt: 0)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "shuffle")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("随机播放")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(Color.appleMusicRed)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Color.appleMusicRed.opacity(0.12))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)

                Divider()
                    .padding(.horizontal, 28)

                // MARK: - Tracklist
                LazyVStack(spacing: 2) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                        trackRow(index: index, track: track)
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 80)
        }
        .avoidsBottomPlayerBar()
        .navigationTitle(album.album)
    }
    @ViewBuilder
    private func trackRow(index: Int, track: Track) -> some View {
        let isCurrent = player.currentTrack?.id == track.id
        let isHovered = hoveredTrackId == track.id

        HStack(spacing: 16) {
            trackIndexView(index: index, isCurrent: isCurrent, isHovered: isHovered)

            Text(track.title)
                .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.appleMusicRed : Color.primary)
                .lineLimit(1)

            Spacer()

            Button {
                track.isFavorite.toggle()
            } label: {
                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 13))
                    .foregroundStyle(track.isFavorite ? Color.appleMusicRed : Color.secondary.opacity(isHovered ? 0.7 : 0))
            }
            .buttonStyle(.plain)

            Text(formatDuration(track.duration))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredTrackId = hovering ? track.id : nil
        }
        .onTapGesture(count: 2) {
            player.setQueue(album.tracks, startingAt: index)
        }
        .contextMenu {
            Button {
                player.setQueue(album.tracks, startingAt: index)
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            Button {
                track.isFavorite.toggle()
            } label: {
                Label(track.isFavorite ? "取消喜爱" : "喜爱", systemImage: track.isFavorite ? "heart.slash" : "heart")
            }
            if !playlists.isEmpty {
                Menu("添加到播放列表") {
                    ForEach(playlists) { playlist in
                        Button(playlist.name) {
                            PlaylistActions.add(track: track, to: playlist, context: modelContext)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trackIndexView(index: Int, isCurrent: Bool, isHovered: Bool) -> some View {
        ZStack {
            if isCurrent && player.isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appleMusicRed)
            } else if isHovered {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.appleMusicRed)
            } else {
                Text("\(index + 1)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.appleMusicRed : Color.secondary)
            }
        }
        .frame(width: 24, alignment: .center)
    }

    private func formatDuration(_ duration: Double) -> String {
        guard !duration.isNaN && !duration.isInfinite && duration >= 0 else { return "0:00" }
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
