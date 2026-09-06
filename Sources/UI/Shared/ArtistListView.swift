import SwiftUI

struct ArtistListView: View {
    let tracks: [Track]
    let playlists: [Playlist]

    private var artists: [String] {
        LibraryGrouping.artistNames(from: tracks)
    }

    var body: some View {
        List {
            ForEach(artists, id: \.self) { artist in
                let artistTracks = LibraryGrouping.tracks(forArtist: artist, in: tracks)
                NavigationLink {
                    LibraryTrackListView(
                        title: artist,
                        subtitle: "\(artistTracks.count) 首",
                        tracks: artistTracks,
                        playlists: playlists
                    )
                } label: {
                    HStack(spacing: 12) {
                        CoverArtView(
                            data: artistTracks.first(where: { $0.coverArtData != nil })?.coverArtData,
                            size: 44,
                            cornerRadius: 22
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist)
                                .font(.headline)
                            Text("\(artistTracks.count) 首")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.plain)
        .safeAreaPadding(.bottom, 72)
        #endif
        .navigationTitle("歌手")
    }
}
