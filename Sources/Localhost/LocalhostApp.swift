import LocalhostKit
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
    static func printInventory() {
        let result = ListenerScanner().scan()
        let rows = ListenerAttributor().present(result.listeners)

        print("scan: \(result.duration), \(rows.count) listeners, oracle: \(result.oracle)")
        for row in rows {
            let port = String(row.listener.port).leftPadded(to: 6)
            let name = row.listener.process.name
            let label = row.label.map { " → \($0)" } ?? ""
            let exposed = row.listener.isExposed ? "  [exposed]" : ""
            print("\(port)  \(name)\(label)\(exposed)")
            if let advice = row.advice { print("        \(advice)") }
        }
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
