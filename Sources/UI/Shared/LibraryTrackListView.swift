import SwiftUI

struct LibraryTrackListView: View {
    let title: String
    let subtitle: String?
    let tracks: [Track]
    let playlists: [Playlist]

    @Bindable private var player = AudioPlayerService.shared

    var body: some View {
        List {
            if tracks.isEmpty {
                ContentUnavailableView("没有歌曲", systemImage: "music.note")
            } else {
                ForEach(tracks) { track in
                    TrackRowView(
                        track: track,
                        isCurrent: player.currentTrack?.id == track.id,
                        playlists: playlists
                    ) {
                        player.setQueue(tracks, startingAt: tracks.firstIndex(where: { $0.id == track.id }) ?? 0)
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.plain)
        #endif
        .avoidsBottomPlayerBar()
        .navigationTitle(title)
        #if os(macOS)
        .navigationSubtitle(subtitle ?? "\(tracks.count) 首")
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !tracks.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        player.setQueue(tracks, startingAt: 0)
                    } label: {
                        Label("播放", systemImage: "play.fill")
                    }
                }
            }
        }
    }
}
