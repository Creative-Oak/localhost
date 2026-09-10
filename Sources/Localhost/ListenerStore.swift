import Foundation
import LocalhostKit
import Observation

/// What the menu is currently showing.
///
/// Scanning happens off the main actor and the result is published here. The
/// store has no timer of its own: the view drives refreshes for exactly as long
/// as it is on screen, so a closed menu costs nothing.
@MainActor
@Observable
final class ListenerStore {
    private(set) var rows: [ListenerPresentation] = []
    private(set) var oracle: OracleStatus = .verified(matched: 0)
    private(set) var lastScanDuration: Duration?
    private(set) var hasScanned = false

    private let scanner: ListenerScanner
    private let attributor: ListenerAttributor

    init(scanner: ListenerScanner = ListenerScanner(),
         attributor: ListenerAttributor = ListenerAttributor()) {
        self.scanner = scanner
        self.attributor = attributor
    }

    /// Seeded with a scan that already happened, for previews and for
    /// rendering the panel without a window server.
    init(rows: [ListenerPresentation], oracle: OracleStatus) {
        self.scanner = ListenerScanner()
        self.attributor = ListenerAttributor()
        self.rows = rows
        self.oracle = oracle
        self.hasScanned = true
    }

    func refresh() async {
        let scanner = self.scanner
        let attributor = self.attributor

        let scanned = await Task.detached(priority: .userInitiated) {
            let result = scanner.scan()
            return (rows: attributor.present(result.listeners),
                    oracle: result.oracle,
                    duration: result.duration)
        }.value

        rows = scanned.rows
        oracle = scanned.oracle
        lastScanDuration = scanned.duration
        hasScanned = true
    }

    /// Refresh until the caller is cancelled — which happens when the menu closes.
    func refreshUntilCancelled(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }
}
