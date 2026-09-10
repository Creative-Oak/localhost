import LocalhostKit
import LocalhostUI
import SwiftUI

@main
enum Main {
    static func main() {
        // `Localhost --list` prints what the menu would show and exits. Useful
        // when someone reports that a port is missing, and it keeps the scan
        // path exercisable without a window server.
        if CommandLine.arguments.contains("--list") {
            Diagnostics.printInventory()
            return
        }
        // `Localhost --render <path>` draws the panel to a PNG with live data.
        // A menu bar panel is otherwise only inspectable by opening it on
        // someone's screen, which makes layout regressions easy to ship.
        if let index = CommandLine.arguments.firstIndex(of: "--render"),
           index + 1 < CommandLine.arguments.count {
            Diagnostics.renderPanel(to: CommandLine.arguments[index + 1])
            return
        }
        if CommandLine.arguments.contains("--soak") {
            Benchmark.soak(
                iterations: 1000,
                pooled: CommandLine.arguments.contains("pooled"))
            return
        }
        if CommandLine.arguments.contains("--bench") {
            Benchmark.run()
            return
        }
        // `--window [dark]` opens the panel as a real window for screenshotting.
        if CommandLine.arguments.contains("--window") {
            PanelWindow.show(dark: CommandLine.arguments.contains("dark"))
            return
        }
        LocalhostApp.main()
    }
}

struct LocalhostApp: App {
    var body: some Scene {
        // `.window`, not the default menu style, because this needs a scroll
        // view now and a search field shortly, and NSMenu does neither well.
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(systemName: "network")
        }
        .menuBarExtraStyle(.window)
    }
}

enum Diagnostics {
    @MainActor
    static func renderPanel(to path: String) {
        // The scan is synchronous, so the panel can be seeded and drawn without
        // an event loop.
        let result = ListenerScanner().scan()
        let store = ListenerStore(
            rows: ListenerAttributor().present(result.listeners),
            oracle: result.oracle)

        let renderer = ImageRenderer(content: MenuContent(store: store, scans: false, maximumListHeight: .infinity))
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            print("render failed")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) — \(store.rows.count) rows, \(Int(image.size.width))x\(Int(image.size.height))pt")
        } catch {
            print("render failed: \(error)")
        }
    }

    static func printInventory() {
        let result = ListenerScanner().scan()

        // Attribution is where the Docker request happens, so it is timed
        // separately: labelling must never be the reason a scan is slow.
        let containers = ContainerLabels()
        let startedAttribution = ContinuousClock.now
        let rows = ListenerAttributor(containers: containers).present(result.listeners)
        let attribution = ContinuousClock.now - startedAttribution

        print("scan: \(result.duration), attribution: \(attribution), \(rows.count) listeners, oracle: \(result.oracle)")
        print("docker: socket \(containers.isAvailable ? "found" : "absent"), \(containers.containers().count) containers")
        for row in rows {
            let port = String(row.listener.port).leftPadded(to: 6)
            let name = row.listener.process.name
            let label = row.label.map { " → \($0)" } ?? ""
            let exposed = row.listener.isExposed ? "  [exposed]" : ""
            let tier: String
            switch row.prominence {
            case .devServer: tier = "dev "
            case .application: tier = "app "
            case .system: tier = "sys "
            }
            print("\(tier)\(port)  \(name)\(label)\(exposed)")
            if let advice = row.advice { print("        \(advice)") }
        }
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
