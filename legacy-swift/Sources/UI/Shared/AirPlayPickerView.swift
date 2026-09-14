import SwiftUI
import AVKit

#if os(iOS)
import UIKit

public struct AirPlayPickerView: UIViewRepresentable {
    public var tintColor: UIColor?
    public var activeTintColor: UIColor?

    public init(
        tintColor: UIColor? = .secondaryLabel,
        activeTintColor: UIColor? = UIColor(red: 0.98, green: 0.14, blue: 0.24, alpha: 1.0)
    ) {
        self.tintColor = tintColor
        self.activeTintColor = activeTintColor
    }

    public func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.backgroundColor = .clear
        if let tintColor {
            picker.tintColor = tintColor
        }
        if let activeTintColor {
            picker.activeTintColor = activeTintColor
        }
        return picker
    }

    public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        if let tintColor {
            uiView.tintColor = tintColor
        }
        if let activeTintColor {
            uiView.activeTintColor = activeTintColor
        }
    }
}
#elseif os(macOS)
import AppKit

public struct AirPlayPickerView: NSViewRepresentable {
    public var normalColor: NSColor?
    public var activeColor: NSColor?

    public init(
        normalColor: NSColor? = .secondaryLabelColor,
        activeColor: NSColor? = NSColor(red: 0.98, green: 0.14, blue: 0.24, alpha: 1.0)
    ) {
        self.normalColor = normalColor
        self.activeColor = activeColor
    }

    public func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.player = AudioPlayerService.shared.avPlayer
        picker.isRoutePickerButtonBordered = false
        applyColors(to: picker)
        return picker
    }

    public func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        nsView.player = AudioPlayerService.shared.avPlayer
        applyColors(to: nsView)
    }

    private func applyColors(to picker: AVRoutePickerView) {
        if let normalColor {
            picker.setRoutePickerButtonColor(normalColor, for: .normal)
            picker.setRoutePickerButtonColor(normalColor, for: .normalHighlighted)
        }
        if let activeColor {
            picker.setRoutePickerButtonColor(activeColor, for: .active)
            picker.setRoutePickerButtonColor(activeColor, for: .activeHighlighted)
        }
    }
}
#endif
