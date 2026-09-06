import SwiftUI

public struct PlaybackControls: View {
    @Bindable var player = AudioPlayerService.shared

    public init() {}

    public var body: some View {
        VStack(spacing: 4) {
            // Scrubber Bar
            HStack(spacing: 8) {
                Text(formatTime(player.currentTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 1.0)
                )
                .tint(.primary)

                Text(formatTime(player.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
            }

            // Buttons
            HStack(spacing: 24) {
                // Play Order (Sequential / Shuffle)
                Button {
                    player.togglePlayOrder()
                } label: {
                    Image(systemName: player.playOrder == .shuffle ? "shuffle" : "shuffle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(player.playOrder == .shuffle ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)

                // Previous
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                // Play / Pause
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                // Next
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                // Repeat Mode
                Button {
                    player.cycleRepeatMode()
                } label: {
                    Image(systemName: repeatIconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(player.repeatMode != .off ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var repeatIconName: String {
        switch player.repeatMode {
        case .off, .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
