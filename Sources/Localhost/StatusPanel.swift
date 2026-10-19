import AppKit
import LocalhostUI
import SwiftUI

/// The menu bar icon and the panel that hangs from it.
///
/// This replaces `MenuBarExtra`, which sizes its window once, when it opens,
/// and offered no way to resize it afterwards: expanding a tier pushed the
/// header and footer out of a window that stayed the same height, and nothing
/// scrolled. Owning the window is what lets it follow the content.
///
/// It keeps `MenuBarExtra`'s behaviour otherwise: it closes on Escape, on a
/// click anywhere else, and on a second click of the icon, and the panel's
/// view is torn down on close so scanning stops with it.
@MainActor
final class StatusPanel: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = MenuPanel()
    /// When the panel last closed by losing focus. A click on the icon makes
    /// the panel resign before the click arrives, and without this the click
    /// would reopen the panel it just closed.
    private var resignedAt = Date.distantPast

    override init() {
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Localhost")
            button.target = self
            button.action = #selector(toggle)
        }
        panel.onClose = { [weak self] in self?.close() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.resignedAt = Date()
                self.close()
            }
        }
    }

    @objc private func toggle() {
        if panel.isVisible {
            close()
        } else if Date().timeIntervalSince(resignedAt) > 0.25 {
            open()
        }
    }

    private func open() {
        guard let button = item.button, let buttonWindow = button.window else { return }

        // A fresh view each time, so its scan loop starts on open and is
        // cancelled on close, exactly as before.
        let hosting = NSHostingView(rootView: MenuContent())
        panel.contentView = hosting
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = Metrics.windowCornerRadius
        panel.contentView?.layer?.cornerCurve = .continuous
        panel.contentView?.layer?.masksToBounds = true

        let size = hosting.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        // Left-aligned under the icon, as system menus are, but kept on screen
        // when the icon sits near the right-hand edge.
        let x = min(max(anchor.minX, screen.minX + 6), screen.maxX - size.width - 6)
        let top = anchor.minY - 5
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: false)

        button.highlight(true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        item.button?.highlight(false)
    }
}

/// A borderless panel that can take keyboard focus without activating the app,
/// so the search field can be typed into while whatever was frontmost stays so.
private final class MenuPanel: NSPanel {
    var onClose: () -> Void = {}

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    /// Escape reaches here only when the panel did not use it — that is, when
    /// the search field was already empty.
    override func cancelOperation(_ sender: Any?) {
        onClose()
    }
}
