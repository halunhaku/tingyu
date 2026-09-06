import SwiftUI

struct AlbumGridView: View {
    let tracks: [Track]
    let playlists: [Playlist]

    private var albums: [AlbumSummary] {
        LibraryGrouping.albums(from: tracks)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
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
                            LibraryTrackListView(
                                title: album.album,
                                subtitle: album.artist,
                                tracks: album.tracks,
                                playlists: playlists
                            )
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
        VStack(alignment: .leading, spacing: 8) {
            CoverArtView(data: album.coverArtData, size: 140, cornerRadius: 10)

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
