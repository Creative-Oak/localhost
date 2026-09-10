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
public final class ListenerStore {
    public private(set) var rows: [ListenerPresentation] = []
    public private(set) var oracle: OracleStatus = .verified(matched: 0)
    public private(set) var lastScanDuration: Duration?
    public private(set) var hasScanned = false
    /// Set when an action failed, so the panel can say so rather than appearing
    /// to have done nothing.
    public private(set) var actionError: String?

    private let scanner: ListenerScanner
    private let attributor: ListenerAttributor
    private let terminator = ProcessTerminator()

    public init(scanner: ListenerScanner = ListenerScanner(),
         attributor: ListenerAttributor = ListenerAttributor()) {
        self.scanner = scanner
        self.attributor = attributor
    }

    /// Seeded with a scan that already happened, for previews and for
    /// rendering the panel without a window server.
    public init(rows: [ListenerPresentation], oracle: OracleStatus) {
        self.scanner = ListenerScanner()
        self.attributor = ListenerAttributor()
        self.rows = rows
        self.oracle = oracle
        self.hasScanned = true
    }

    public func refresh() async {
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

    /// Signals a process, then rescans so the row reflects reality.
    ///
    /// The terminator re-verifies `(pid, startedAt)` immediately before
    /// signalling and refuses if the process behind that pid has changed, so a
    /// row that has gone stale between the scan and the click cannot take an
    /// innocent process with it.
    public func terminate(
        _ row: ListenerPresentation,
        using signal: ProcessTerminator.Signal = .terminate
    ) async {
        await terminate([row], using: signal)
    }

    /// Signals several processes as one action, for quitting a whole project.
    ///
    /// Each one is verified independently, so a single stale row in the group
    /// stops only itself. Failures are reported together rather than the first
    /// one silently winning.
    public func terminate(
        _ rows: [ListenerPresentation],
        using signal: ProcessTerminator.Signal = .terminate
    ) async {
        var failures: [String] = []
        for row in rows {
            do {
                try terminator.terminate(row.listener.process, using: signal)
            } catch let failure as ProcessTerminator.Failure {
                // "Already exited" is the outcome that was wanted, not an error.
                if failure != .alreadyExited { failures.append(failure.description) }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        actionError = failures.isEmpty ? nil : Set(failures).sorted().joined(separator: " ")
        await refresh()
    }

    public func dismissActionError() {
        actionError = nil
    }

    /// Refresh until the caller is cancelled — which happens when the menu closes.
    public func refreshUntilCancelled(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }
}
