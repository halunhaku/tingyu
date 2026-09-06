import SwiftUI

public struct CoverArtView: View {
    public let data: Data?
    public let size: CGFloat
    public let cornerRadius: CGFloat

    public init(data: Data?, size: CGFloat = 48, cornerRadius: CGFloat = 8) {
        self.data = data
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        Group {
            #if canImport(UIKit)
            if let data = data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
            #elseif canImport(AppKit)
            if let data = data, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
            #endif
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: size * 0.08, x: 0, y: size * 0.04)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.indigo.opacity(0.8), Color.purple.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
