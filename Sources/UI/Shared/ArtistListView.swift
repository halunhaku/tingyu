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
                    ArtistDetailView(
                        artist: artist,
                        artistTracks: artistTracks,
                        playlists: playlists
                    )
                } label: {
                    HStack(spacing: 12) {
                        ArtistAvatarView(
                            artist: artist,
                            fallbackData: artistTracks.first(where: { $0.coverArtData != nil })?.coverArtData,
                            size: 44
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
        #endif
        .avoidsBottomPlayerBar()
        .navigationTitle("艺人")
    }
}
