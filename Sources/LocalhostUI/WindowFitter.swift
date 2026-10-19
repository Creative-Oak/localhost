import AppKit
import SwiftUI

/// Keeps the panel's window the size of its content.
///
/// `MenuBarExtra` sizes its window once, when it opens. Expanding a tier
/// afterwards made the content taller than the window, which clipped it — and
/// because the list was still under its scrolling limit there was no scroll
/// view either, so the new rows were simply unreachable. SwiftUI offers no way
/// to ask for a resize, so this reaches the hosting window and does it.
///
/// The top edge stays put: the panel hangs from the menu bar, and growing
/// upwards would move it away from the icon it belongs to.
struct WindowFitter: NSViewRepresentable {
    /// Anything that changes the content's height. The value is not used, only
    /// the fact that it changed.
    var height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // After this layout pass, so `fittingSize` reflects the new content.
        DispatchQueue.main.async {
            guard let window = view.window, let content = window.contentView else { return }
            let fitting = content.fittingSize.height
            guard fitting > 0 else { return }
            let current = window.contentLayoutRect.height
            guard abs(fitting - current) > 0.5 else { return }

            var frame = window.frame
            let delta = window.frameRect(forContentRect: NSRect(
                x: 0, y: 0, width: frame.width, height: fitting)).height - frame.height
            frame.size.height += delta
            frame.origin.y -= delta
            window.setFrame(frame, display: true)
        }
    }
}

extension NSScreen {
    /// Room for the list once the panel's own header, search field and footer
    /// are accounted for, so a long list scrolls instead of running off the
    /// bottom of a small display.
    @MainActor
    static var listHeightLimit: CGFloat {
        let available = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
        return max(240, available - 200)
    }
}
