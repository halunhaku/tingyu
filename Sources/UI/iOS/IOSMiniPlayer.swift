import SwiftUI

#if os(iOS)
public struct IOSMiniPlayer: View {
    public let onExpand: () -> Void
    @Bindable var player = AudioPlayerService.shared

    public init(onExpand: @escaping () -> Void) {
        self.onExpand = onExpand
    }

    public var body: some View {
        if let track = player.currentTrack {
            Button {
                onExpand()
            } label: {
                HStack(spacing: 12) {
                    CoverArtView(data: track.coverArtData, size: 44, cornerRadius: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(player.playbackError ?? track.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(player.playbackError == nil ? Color.secondary : Color.red.opacity(0.85))
                            .lineLimit(1)
                    }

                    Spacer()

                    // Play / Pause Button
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)

                    // Next Button
                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 44)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.16), radius: 12, x: 0, y: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 56) // Float right above the TabBar
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
#endif
