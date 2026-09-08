import SwiftUI

#if os(macOS)
public struct MacOSMenuBarExtra: View {
    @Bindable var player = AudioPlayerService.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let track = player.currentTrack {
                HStack(spacing: 10) {
                    CoverArtView(data: track.coverArtData, size: 40, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        track.isFavorite.toggle()
                    } label: {
                        Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 13))
                            .foregroundStyle(track.isFavorite ? Color.appleMusicRed : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(track.isFavorite ? "取消喜爱" : "喜爱")
                }

                if player.duration > 0 {
                    VStack(spacing: 4) {
                        ProgressView(value: min(max(player.currentTime / max(player.duration, 1), 0), 1))
                            .tint(Color.appleMusicRed)
                        HStack {
                            Text(formatTime(player.currentTime))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatTime(player.duration))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 24) {
                    Spacer()
                    Button {
                        player.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 14))
                    }
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 14))
                    }
                    Spacer()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            } else {
                Text("暂未播放音乐")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("打开听屿") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                }
            }

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 250)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif
