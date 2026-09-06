import SwiftUI

enum PlayerChrome {
    static let bottomOverlap: CGFloat = 84
}

extension View {
    /// Keeps list content and the scroll indicator above the floating player bar.
    func avoidsBottomPlayerBar() -> some View {
        #if os(macOS)
        self
        #else
        self.safeAreaPadding(.bottom, 72)
        #endif
    }
}
