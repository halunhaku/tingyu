import SwiftUI

enum PlayerChrome {
    static let bottomOverlap: CGFloat = 84
}

extension View {
    /// Keeps list content and the scroll indicator above the floating player bar.
    func avoidsBottomPlayerBar() -> some View {
        #if os(macOS)
        self
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 84)
            }
            .contentMargins(.top, 16, for: .scrollIndicators)
            .contentMargins(.bottom, 84, for: .scrollIndicators)
        #else
        self.safeAreaPadding(.bottom, 72)
        #endif
    }
}
