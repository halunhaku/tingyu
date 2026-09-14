import SwiftUI

public struct FluidBackgroundView: View {
    public let coverData: Data?

    public init(coverData: Data?) {
        self.coverData = coverData
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Dynamic fluid color blobs
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height

                Circle()
                    .fill(dominantColor.opacity(0.55))
                    .frame(width: max(width, height) * 0.8)
                    .offset(x: -width * 0.2, y: -height * 0.2)
                    .blur(radius: 80)

                Circle()
                    .fill(secondaryColor.opacity(0.45))
                    .frame(width: max(width, height) * 0.7)
                    .offset(x: width * 0.3, y: height * 0.3)
                    .blur(radius: 90)

                Circle()
                    .fill(Color.indigo.opacity(0.35))
                    .frame(width: max(width, height) * 0.6)
                    .offset(x: 0, y: height * 0.1)
                    .blur(radius: 85)
            }
            .ignoresSafeArea()

            #if os(macOS)
            VisualEffectBlur(material: .fullScreenUI, blendingMode: .withinWindow)
                .ignoresSafeArea()
            #else
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            #endif
        }
    }

    private var dominantColor: Color {
        // Fallback or dynamically blended color
        if coverData != nil {
            return Color(red: 0.25, green: 0.15, blue: 0.45)
        }
        return Color(red: 0.15, green: 0.2, blue: 0.35)
    }

    private var secondaryColor: Color {
        if coverData != nil {
            return Color(red: 0.65, green: 0.25, blue: 0.4)
        }
        return Color(red: 0.1, green: 0.3, blue: 0.45)
    }
}

#if os(macOS)
import AppKit

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
#endif
