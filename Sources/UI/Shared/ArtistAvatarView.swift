import SwiftUI

public struct ArtistAvatarView: View {
    public let artist: String
    public let fallbackData: Data?
    public let size: CGFloat
    public var showsShadow: Bool = true

    @State private var avatarData: Data?

    public init(artist: String, fallbackData: Data?, size: CGFloat = 44, showsShadow: Bool = true) {
        self.artist = artist
        self.fallbackData = fallbackData
        self.size = size
        self.showsShadow = showsShadow
    }

    public var body: some View {
        Group {
            if let avatarData, let image = platformImage(from: avatarData) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let fallbackData, let image = platformImage(from: fallbackData) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                defaultPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .shadow(
            color: showsShadow ? Color.black.opacity(0.18) : .clear,
            radius: showsShadow ? size * 0.08 : 0,
            x: 0,
            y: showsShadow ? size * 0.04 : 0
        )
        .task(id: artist) {
            if avatarData == nil {
                avatarData = await ArtistAvatarStore.shared.avatar(for: artist)
            }
        }
    }

    private var defaultPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.indigo.opacity(0.8), Color.purple.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.mic")
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func platformImage(from data: Data) -> Image? {
        #if canImport(UIKit)
        if let uiImage = UIImage(data: data) {
            return Image(uiImage: uiImage)
        }
        #elseif canImport(AppKit)
        if let nsImage = NSImage(data: data) {
            return Image(nsImage: nsImage)
        }
        #endif
        return nil
    }
}
