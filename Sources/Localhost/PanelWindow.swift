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
    static func show(
        dark: Bool,
        expandAll: Bool = false,
        confirmDemo: Bool = false,
        sample: Bool = false,
        grow: Bool = false
    ) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let store: ListenerStore
        if sample {
            store = ListenerStore(rows: SampleListeners.rows, oracle: .verified(matched: SampleListeners.rows.count))
        } else {
            let result = ListenerScanner().scan()
            store = ListenerStore(
                rows: ListenerAttributor().present(result.listeners),
                oracle: result.oracle)
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: expandAll ? 900 : 600),
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
        panel.contentView?.layer?.cornerRadius = 20
        panel.contentView?.layer?.cornerCurve = .continuous
        panel.contentView?.layer?.masksToBounds = true

        // Preselect a row so the highlight is visible in the screenshot.
        var content = MenuContent(
            store: store,
            scans: false,
            initialSelection: grow ? nil : store.rows.first(where: {
                expandAll ? $0.prominence == .system : $0.prominence == .devServer
            })?.id,
            highlightFooter: !expandAll && !grow,
            initiallyExpanded: expandAll ? [.application, .system] : [],
            // Second dev row hovered, first selected: the two states side by
            // side is the whole point of looking at this.
            forceHoverOn: expandAll ? nil : store.rows
                .filter { $0.prominence == .devServer }
                .dropFirst().first?.id)
        content.expandsAfterAppearing = grow
        let hosting = NSHostingView(rootView: content)
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        // Hung from a fixed top edge, as the real panel hangs from the menu
        // bar, so growth shows up as the bottom edge moving.
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.midX - 170, y: screen.maxY - 20))
        }
        panel.orderFrontRegardless()

        print("window: \(panel.windowNumber)")
        fflush(stdout)

        // `--window confirm` raises the termination alert a moment after the
        // panel appears, so that a modal can be checked for existence from
        // outside. A dialog that silently fails to present is otherwise
        // invisible to every test and every screenshot.
        if confirmDemo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                _ = AppServices.confirmTermination(
                    title: "Quit campo — node (pid 60964) on port 3000?",
                    detail: "Quit asks it to stop and lets it shut down cleanly. Force quit does not.")
            }
        }
        application.run()
    }
}

/// A plausible machine, for screenshots taken where the real port table is out
/// of reach — a sandboxed shell sees no listeners at all.
enum SampleListeners {
    static var rows: [ListenerPresentation] {
        let me = getuid()
        func process(_ pid: pid_t, _ name: String, ours: Bool = true, path: String? = nil) -> ProcessIdentity {
            ProcessIdentity(pid: pid, startedAt: ours ? 1 : nil, uid: ours ? me : 0, name: name,
                            executablePath: path, workingDirectory: ours ? "/tmp" : nil)
        }
        func row(_ port: UInt16, _ process: ProcessIdentity, _ attribution: ListenerPresentation.Attribution,
                 runtime: Runtime? = nil, branch: String? = nil, exposed: Bool = false) -> ListenerPresentation {
            ListenerPresentation(
                listener: Listener(port: port, addresses: [exposed ? "0.0.0.0" : "127.0.0.1"],
                                   families: [.ipv4], process: process),
                attribution: attribution, runtime: runtime, branch: branch)
        }
        func project(_ name: String) -> ListenerPresentation.Attribution {
            .project(name: name, root: URL(fileURLWithPath: "/Users/dev/\(name)"), source: .packageJSON)
        }
        func daemon(_ port: UInt16, _ name: String) -> ListenerPresentation.Attribution {
            KnownDaemons.daemon(port: port, processName: name).map { .knownDaemon($0) } ?? .unavailable
        }
        return [
            row(3000, process(60964, "node"), project("campo"), runtime: Runtime(name: "Next.js", version: "16.2.12"), branch: "feature/checkout"),
            row(3001, process(60971, "node"), project("campo"), runtime: Runtime(name: "Storybook", version: "9.1"), branch: "feature/checkout"),
            row(5173, process(61210, "node"), project("atlas-web"), runtime: Runtime(name: "Vite", version: "7.0.4"), branch: "main", exposed: true),
            row(8000, process(61388, "python3.13"), project("ledger-api"), runtime: Runtime(name: "Uvicorn"), branch: "fix/rounding"),
            row(5432, process(1022, "postgres"), .nothing, runtime: Runtime(name: "PostgreSQL", version: "17")),
            row(7265, process(912, "Raycast", path: "/Applications/Raycast.app/Contents/MacOS/Raycast"), .nothing),
            row(27015, process(1555, "Figma Agent", path: "/Applications/Figma Agent.app/Contents/MacOS/figma_agent"), .nothing),
            row(45112, process(2207, "Code Helper", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper"), .nothing),
            row(5000, process(480, "ControlCenter", path: "/System/Library/CoreServices/ControlCenter.app"), daemon(5000, "ControlCenter"), exposed: true),
            row(7000, process(480, "ControlCenter", path: "/System/Library/CoreServices/ControlCenter.app"), daemon(7000, "ControlCenter"), exposed: true),
            row(88, process(1, "launchd", ours: false), daemon(88, "launchd")),
            row(631, process(1, "launchd", ours: false), daemon(631, "launchd")),
            row(49152, process(388, "rapportd", ours: false), .unavailable),
            row(55920, process(402, "identityservicesd", ours: false), .unavailable),
        ]
    }
}
