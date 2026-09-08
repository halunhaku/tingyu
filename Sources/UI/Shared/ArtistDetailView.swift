import SwiftUI
import SwiftData

struct ArtistDetailView: View {
    let artist: String
    let artistTracks: [Track]
    let playlists: [Playlist]

    @Environment(\.modelContext) private var modelContext
    @Bindable private var player = AudioPlayerService.shared
    @State private var hoveredTrackId: String?

    private var artistAlbums: [AlbumSummary] {
        LibraryGrouping.albums(from: artistTracks)
    }

    private var avatarCoverData: Data? {
        artistTracks.first(where: { $0.coverArtData != nil })?.coverArtData
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // MARK: - Artist Header
                HStack(alignment: .center, spacing: 24) {
                    ArtistAvatarView(
                        artist: artist,
                        fallbackData: avatarCoverData,
                        size: 130
                    )
                    .shadow(color: Color.black.opacity(0.2), radius: 12, x: 0, y: 6)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("艺人")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        Text(artist)
                            .font(.system(size: 32, weight: .bold))
                            .lineLimit(1)

                        Text("\(artistTracks.count) 首歌曲 · \(artistAlbums.count) 张专辑")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        // Play & Shuffle
                        HStack(spacing: 12) {
                            Button {
                                player.setQueue(artistTracks, startingAt: 0)
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
                                player.setQueue(artistTracks.shuffled(), startingAt: 0)
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

                // MARK: - Top Songs Section
                if !artistTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("热门歌曲")
                            .font(.title2.weight(.bold))
                            .padding(.horizontal, 28)

                        LazyVStack(spacing: 2) {
                            ForEach(Array(artistTracks.prefix(5).enumerated()), id: \.element.id) { index, track in
                                songRow(index: index, track: track)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }

                // MARK: - Albums Section
                if !artistAlbums.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("专辑")
                            .font(.title2.weight(.bold))
                            .padding(.horizontal, 28)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 20) {
                                ForEach(artistAlbums) { album in
                                    NavigationLink {
                                        AlbumDetailView(album: album, playlists: playlists)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            CoverArtView(data: album.coverArtData, size: 140, cornerRadius: 10)
                                                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                                            Text(album.album)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            if let year = album.year {
                                                Text(String(year))
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(width: 140, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 28)
                        }
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .avoidsBottomPlayerBar()
        .navigationTitle(artist)
    }

    @ViewBuilder
    private func songRow(index: Int, track: Track) -> some View {
        let isCurrent = player.currentTrack?.id == track.id
        let isHovered = hoveredTrackId == track.id

        HStack(spacing: 14) {
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
            .frame(width: 20, alignment: .center)

            CoverArtView(data: track.coverArtData, size: 36, cornerRadius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(isCurrent ? Color.appleMusicRed : Color.primary)
                    .lineLimit(1)
                Text(track.album)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                track.isFavorite.toggle()
            } label: {
                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 12))
                    .foregroundStyle(track.isFavorite ? Color.appleMusicRed : Color.secondary.opacity(isHovered ? 0.7 : 0))
            }
            .buttonStyle(.plain)

            Text(formatDuration(track.duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredTrackId = hovering ? track.id : nil
        }
        .onTapGesture(count: 2) {
            player.setQueue(artistTracks, startingAt: index)
        }
        .contextMenu {
            Button {
                player.setQueue(artistTracks, startingAt: index)
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

    private func formatDuration(_ duration: Double) -> String {
        guard !duration.isNaN && !duration.isInfinite && duration >= 0 else { return "0:00" }
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
