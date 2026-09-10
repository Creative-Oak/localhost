import Darwin
import Foundation
import Testing
@testable import LocalhostKit
@testable import LocalhostUI

/// The path between the confirmation dialog and the signal.
@MainActor
@Suite("Termination flow", .serialized)
struct TerminationFlowTests {
    private func spawnAndDescribe() throws -> (Process, ListenerPresentation) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()

        var info: proc_bsdinfo?
        for _ in 0..<200 {
            if let found = ProcessDetails.bsdInfo(of: process.processIdentifier) { info = found; break }
            usleep(10_000)
        }
        let bsd = try #require(info)

        let row = ListenerPresentation(
            listener: Listener(
                port: 39_999,
                addresses: ["127.0.0.1"],
                families: [.ipv4],
                process: ProcessIdentity(
                    pid: process.processIdentifier,
                    startedAt: time_t(bsd.pbi_start_tvsec),
                    uid: bsd.pbi_uid,
                    name: "sleep")),
            attribution: .nothing)
        return (process, row)
    }

    private func waitForExit(_ pid: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if ProcessDetails.bsdInfo(of: pid) == nil { return true }
            usleep(20_000)
        }
        return ProcessDetails.bsdInfo(of: pid) == nil
    }

    @Test("terminating through the store stops the process and reports no error")
    func terminationSucceeds() async throws {
        let (process, row) = try spawnAndDescribe()
        defer { if process.isRunning { process.terminate() } }

        let store = ListenerStore(rows: [row], oracle: .verified(matched: 1))
        await store.terminate(row)

        #expect(waitForExit(row.listener.process.pid))
        #expect(store.actionError == nil)
    }

    @Test("a stale row reports an error and leaves the process alone")
    func staleRowIsRefusedAndExplained() async throws {
        let (process, row) = try spawnAndDescribe()
        defer { if process.isRunning { process.terminate() } }

        // The row was drawn before the pid was recycled onto something else.
        let stale = ListenerPresentation(
            listener: Listener(
                port: row.listener.port,
                addresses: row.listener.addresses,
                families: row.listener.families,
                process: ProcessIdentity(
                    pid: row.listener.process.pid,
                    startedAt: row.listener.process.startedAt! - 900,
                    uid: row.listener.process.uid,
                    name: "sleep")),
            attribution: .nothing)

        let store = ListenerStore(rows: [stale], oracle: .verified(matched: 1))
        await store.terminate(stale)

        #expect(ProcessDetails.bsdInfo(of: row.listener.process.pid) != nil,
                "a stale row must not signal anything")
        let message = try #require(store.actionError)
        #expect(message.contains("something else"), "got: \(message)")
    }

}
