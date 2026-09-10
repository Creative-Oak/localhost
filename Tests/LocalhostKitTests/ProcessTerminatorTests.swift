import Darwin
import Foundation
import Testing
@testable import LocalhostKit

@Suite("ProcessTerminator", .serialized)
struct ProcessTerminatorTests {
    /// Starts a real process and describes it exactly as a scan would.
    private func spawnSleep() throws -> (process: Process, identity: ProcessIdentity) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()

        // Give the kernel a moment to publish the process table entry.
        var info: proc_bsdinfo?
        for _ in 0..<50 {
            if let found = ProcessDetails.bsdInfo(of: process.processIdentifier) {
                info = found
                break
            }
            usleep(10_000)
        }
        let bsd = try #require(info, "spawned process never appeared")
        return (process, ProcessIdentity(
            pid: process.processIdentifier,
            startedAt: time_t(bsd.pbi_start_tvsec),
            uid: bsd.pbi_uid,
            name: "sleep"))
    }

    private func isRunning(_ pid: pid_t) -> Bool {
        ProcessDetails.bsdInfo(of: pid) != nil
    }

    private func waitForExit(_ pid: pid_t, within seconds: Double = 3) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isRunning(pid) { return true }
            usleep(20_000)
        }
        return !isRunning(pid)
    }

    @Test("terminates a process it owns")
    func terminatesOwnedProcess() throws {
        let (process, identity) = try spawnSleep()
        defer { if process.isRunning { process.terminate() } }

        try ProcessTerminator().terminate(identity)
        #expect(waitForExit(identity.pid), "process survived SIGTERM")
    }

    /// The reason `(pid, startedAt)` exists rather than a bare pid.
    @Test("refuses a stale identity rather than signalling the wrong process")
    func refusesStaleIdentity() throws {
        let (process, identity) = try spawnSleep()
        defer { if process.isRunning { process.terminate() } }

        // Same live pid, wrong start time: the row is stale and the pid has
        // been recycled onto something else.
        let stale = ProcessIdentity(
            pid: identity.pid,
            startedAt: identity.startedAt! - 500,
            uid: identity.uid,
            name: identity.name)

        #expect(throws: ProcessTerminator.Failure.self) {
            try ProcessTerminator().terminate(stale)
        }
        #expect(isRunning(identity.pid), "a stale identity must not signal anything")
    }

    @Test("refuses a process with no verifiable identity")
    func refusesUnverifiableIdentity() throws {
        let (process, identity) = try spawnSleep()
        defer { if process.isRunning { process.terminate() } }

        // startedAt is nil exactly when the process is another user's.
        let unverifiable = ProcessIdentity(
            pid: identity.pid, startedAt: nil, uid: 0, name: "someone else's")

        #expect(throws: ProcessTerminator.Failure.notPermitted) {
            try ProcessTerminator().terminate(unverifiable)
        }
        #expect(isRunning(identity.pid))
    }

    @Test("reports an already-exited process without complaint")
    func handlesAlreadyExitedProcess() throws {
        let (process, identity) = try spawnSleep()
        process.terminate()
        process.waitUntilExit()
        _ = waitForExit(identity.pid)

        #expect(throws: ProcessTerminator.Failure.alreadyExited) {
            try ProcessTerminator().terminate(identity)
        }
    }

    @Test("force terminates a process")
    func forceTerminates() throws {
        let (process, identity) = try spawnSleep()
        defer { if process.isRunning { process.terminate() } }

        try ProcessTerminator().terminate(identity, using: .force)
        #expect(waitForExit(identity.pid), "process survived SIGKILL")
    }

    /// The escalation the interface offers when a dev server ignores the first
    /// request. That SIGKILL cannot be caught is the kernel's guarantee, not
    /// this code's — what is worth asserting is that `.force` really maps to it
    /// and that `.terminate` really does not.
    @Test("force gets past a process that ignores SIGTERM")
    func forceOvercomesIgnoredSIGTERM() throws {
        let interpreter = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: interpreter) else { return }

        // The child announces that its handler is installed. Sleeping a fixed
        // time instead makes the test race interpreter startup: SIGTERM arrives
        // before SIG_IGN is set, the process dies, and the failure looks like a
        // terminator bug rather than a slow import.
        let ready = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("terminator-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }

        // A shell will not do: with `sleep` as its last command it execs, and
        // the trap goes with it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = [
            "-c",
            """
            import signal, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            open(\(ready.path.debugDescription), "w").write("ready")
            time.sleep(30)
            """,
        ]
        guard (try? process.run()) != nil else { return }
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }

        var info: proc_bsdinfo?
        for _ in 0..<200 {
            if let found = ProcessDetails.bsdInfo(of: process.processIdentifier) { info = found; break }
            usleep(10_000)
        }
        let bsd = try #require(info)
        let identity = ProcessIdentity(
            pid: process.processIdentifier,
            startedAt: time_t(bsd.pbi_start_tvsec),
            uid: bsd.pbi_uid,
            name: "python3")

        var installed = false
        for _ in 0..<500 where !installed {
            if FileManager.default.fileExists(atPath: ready.path) { installed = true; break }
            usleep(10_000)
        }
        try #require(installed, "child never installed its signal handler")

        try ProcessTerminator().terminate(identity, using: .terminate)
        usleep(300_000)
        #expect(isRunning(identity.pid), "SIGTERM should have been ignored")

        try ProcessTerminator().terminate(identity, using: .force)
        #expect(waitForExit(identity.pid), "process survived SIGKILL")
    }
}

@Suite("Row actions")
struct ListenerActionTests {
    private func row(
        port: UInt16 = 3000,
        ours: Bool = true,
        cwd: String? = "/tmp/project",
        project: Bool = true
    ) -> ListenerPresentation {
        ListenerPresentation(
            listener: Listener(
                port: port,
                addresses: ["0.0.0.0"],
                families: [.ipv4],
                process: ProcessIdentity(
                    pid: 42,
                    startedAt: ours ? 1 : nil,
                    uid: ours ? getuid() : 0,
                    name: "node",
                    workingDirectory: cwd)),
            attribution: project
                ? .project(name: "campo", root: URL(fileURLWithPath: "/tmp/project"), source: .packageJSON)
                : .nothing)
    }

    @Test("offers localhost, not the bound address")
    func urlUsesLocalhost() {
        // A server on 0.0.0.0 is not reachable at http://0.0.0.0/.
        #expect(row().localURL?.absoluteString == "http://localhost:3000")
    }

    @Test("reveals the project root when there is one")
    func revealsProjectRoot() {
        #expect(row().folderToReveal?.path == "/tmp/project")
    }

    @Test("falls back to the working directory with no project")
    func revealsWorkingDirectory() {
        let target = row(cwd: "/tmp/elsewhere", project: false).folderToReveal
        #expect(target?.path == "/tmp/elsewhere")
    }

    @Test("offers nothing to reveal for a process rooted at /")
    func doesNotRevealRoot() {
        #expect(row(cwd: "/", project: false).folderToReveal == nil)
    }

    @Test("another user's process cannot be quit")
    func foreignProcessCannotBeTerminated() {
        let foreign = row(ours: false, cwd: nil, project: false)
        #expect(!foreign.canTerminate)
        #expect(!foreign.supports(.terminate))
        #expect(!foreign.availableActions.contains(.terminate))
    }

    @Test("our own process can be quit")
    func ourProcessCanBeTerminated() {
        #expect(row().supports(.terminate))
    }

    @Test("a confirmation names the process unambiguously")
    func confirmationNamesTheProcess() {
        let description = row().terminationDescription
        #expect(description.contains("campo"))
        #expect(description.contains("node"))
        #expect(description.contains("42"))
        #expect(description.contains("3000"))
    }
}

@Suite("Opening in a browser")
struct BrowsableTests {
    private func row(
        port: UInt16,
        project: String? = "campo",
        runtime: String? = "Next.js",
        executable: String? = nil,
        ours: Bool = true
    ) -> ListenerPresentation {
        ListenerPresentation(
            listener: Listener(
                port: port,
                addresses: ["127.0.0.1"],
                families: [.ipv4],
                process: ProcessIdentity(
                    pid: 1,
                    startedAt: ours ? 1 : nil,
                    uid: ours ? getuid() : 0,
                    name: "node",
                    executablePath: executable,
                    workingDirectory: "/tmp")),
            attribution: project.map {
                .project(name: $0, root: URL(fileURLWithPath: "/tmp"), source: .packageJSON)
            } ?? .nothing,
            runtime: runtime.map { Runtime(name: $0) })
    }

    @Test("a dev server is browsable")
    func devServerIsBrowsable() {
        let server = row(port: 3000)
        #expect(server.servesHTTP)
        #expect(server.supports(.openInBrowser))
        #expect(!server.supports(.copyPort), "a URL is the more useful thing here")
    }

    @Test("an application of yours is not")
    func applicationIsNotBrowsable() {
        // Clicking OneDrive on 42050 opened a tab that failed to connect.
        let sync = row(port: 42050, project: nil, runtime: nil,
                       executable: "/Applications/OneDrive.app/Contents/MacOS/OneDrive")
        #expect(sync.prominence == .application)
        #expect(!sync.servesHTTP)
        #expect(!sync.supports(.openInBrowser))
        #expect(!sync.supports(.copyURL))
    }

    @Test("a system daemon is not")
    func systemIsNotBrowsable() {
        let daemon = row(port: 5900, project: nil, runtime: nil, ours: false)
        #expect(!daemon.servesHTTP)
        #expect(!daemon.supports(.openInBrowser))
    }

    @Test("a database is not, even when it is yours", arguments: [
        5432, 3306, 6379, 27017, 11211,
    ] as [UInt16])
    func databasePortIsNotBrowsable(port: UInt16) {
        // A Postgres container is a dev server by every other measure, and
        // http://localhost:5432 is still a protocol error.
        let database = row(port: port, runtime: nil)
        #expect(database.prominence == .devServer)
        #expect(!database.servesHTTP)
        #expect(database.supports(.copyPort))
    }

    @Test("a database is disqualified by its runtime as well as its port")
    func databaseRuntimeIsNotBrowsable() {
        // Postgres moved off 5432 is still Postgres.
        let database = row(port: 6000, runtime: "PostgreSQL")
        #expect(!database.servesHTTP)
    }

    @Test("something browsable on an unusual port stays browsable")
    func unusualHTTPPortIsBrowsable() {
        #expect(row(port: 4321, runtime: "Vite").servesHTTP)
    }

    @Test("every row offers exactly one way to copy")
    func exactlyOneCopyAction() {
        for row in [row(port: 3000), row(port: 5432, runtime: nil),
                    row(port: 42050, project: nil, runtime: nil, ours: false)] {
            let copies = row.availableActions.filter { $0 == .copyURL || $0 == .copyPort }
            #expect(copies.count == 1, "port \(row.listener.port) offered \(copies)")
        }
    }
}
