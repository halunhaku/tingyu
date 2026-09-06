import SwiftUI

#if os(macOS)
public struct MacOSMenuBarExtra: View {
    @Bindable var player = AudioPlayerService.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let track = player.currentTrack {
                HStack(spacing: 10) {
                    CoverArtView(data: track.coverArtData, size: 36, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Divider()

                HStack {
                    Button {
                        player.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                    }

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    }

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            } else {
                Text("暂未播放音乐")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("打开听屿") {
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}
#endif
