import SwiftUI

struct AlbumGridView: View {
    let tracks: [Track]
    let playlists: [Playlist]

    @Bindable private var player = AudioPlayerService.shared
    @State private var hoveredAlbumId: String?

    private var albums: [AlbumSummary] {
        LibraryGrouping.albums(from: tracks)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)
    ]
    var body: some View {
        ScrollView {
            if albums.isEmpty {
                ContentUnavailableView("没有专辑", systemImage: "square.stack")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(albums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album, playlists: playlists)
                        } label: {
                            albumCell(album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
        .avoidsBottomPlayerBar()
        .navigationTitle("专辑")
    }

    private func albumCell(_ album: AlbumSummary) -> some View {
        let isHovered = hoveredAlbumId == album.id
        let isCurrentAlbum = album.tracks.contains(where: { $0.id == player.currentTrack?.id })

        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                CoverArtView(data: album.coverArtData, size: 160, cornerRadius: 10)

                // Floating Play Button on Hover / Playing
                if isHovered || (isCurrentAlbum && player.isPlaying) {
                    Button {
                        if isCurrentAlbum && player.isPlaying {
                            player.togglePlayPause()
                        } else {
                            player.setQueue(album.tracks, startingAt: 0)
                        }
                    } label: {
                        Image(systemName: (isCurrentAlbum && player.isPlaying) ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.appleMusicRed)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .onHover { hovering in
                hoveredAlbumId = hovering ? album.id : nil
            }

            Text(album.album)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(album.artist)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
