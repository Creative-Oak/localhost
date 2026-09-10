import AppKit
import LocalhostKit
import LocalhostUI
import SwiftUI

/// Opens the panel in an ordinary window so it can be screenshotted.
///
/// `ImageRenderer` draws the SwiftUI view tree without a window behind it, so
/// it cannot show a material, a vibrancy effect, or a real selection highlight
/// — exactly the things that decide whether this looks like a system menu.
/// This mode puts the same content in a real `NSPanel` and prints its window
/// number, so `screencapture -l` can capture this app's window and nothing
/// else on the screen.
@MainActor
enum PanelWindow {
    static func show(dark: Bool) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let result = ListenerScanner().scan()
        let store = ListenerStore(
            rows: ListenerAttributor().present(result.listeners),
            oracle: result.oracle)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
            // Borderless, because the real menu bar panel has no title bar and
            // a screenshot with one would flatter the layout dishonestly.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Transparent, so the material in the content view is what shows.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The real menu panel has a generously rounded corner. A borderless
        // square window hid an entire class of bug: a highlight running past
        // the corner arc and drawing onto the desktop. Deliberately rounder
        // than the system's, so anything that would escape shows up here first.
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 18
        panel.contentView?.layer?.cornerCurve = .continuous
        panel.contentView?.layer?.masksToBounds = true

        // Preselect a row so the highlight is visible in the screenshot.
        let hosting = NSHostingView(rootView: MenuContent(
            store: store,
            scans: false,
            initialSelection: store.rows.first(where: { $0.prominence == .yours })?.id,
            highlightFooter: true))
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        panel.orderFrontRegardless()

        print("window: \(panel.windowNumber)")
        fflush(stdout)
        application.run()
    }
}
