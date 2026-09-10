import AppKit
import SwiftUI

/// The panel's background material.
///
/// The HIG is explicit that Liquid Glass belongs to the functional layer —
/// controls and navigation floating above content — and *not* to the content
/// layer, which is what this panel mostly is: a list of text. For a
/// popover-like surface carrying a significant amount of text it asks for a
/// standard material with vibrant system colors on top.
///
/// `.menu` is the material the system's own menu bar extras use, and
/// `.behindWindow` blends with the desktop rather than with the app, which is
/// what makes a menu read as part of macOS instead of as a white rectangle.
///
/// `NSVisualEffectView` handles Reduce Transparency and Increase Contrast on
/// its own, which is a second reason to use it rather than a hand-rolled
/// translucent fill.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        // `.active` keeps the material lit even when the panel is not key,
        // which is the normal state for a menu bar extra.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
