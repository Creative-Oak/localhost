import Darwin
import Foundation
import Testing
@testable import LocalhostKit

@Suite("Start command", .serialized)
struct StartCommandTests {
    private func spawn(_ arguments: [String], directory: URL? = nil) throws -> (Process, ProcessIdentity) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        if let directory { process.currentDirectoryURL = directory }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        var info: proc_bsdinfo?
        for _ in 0..<200 {
            if let found = ProcessDetails.bsdInfo(of: process.processIdentifier) { info = found; break }
            usleep(10_000)
        }
        let bsd = try #require(info)
        return (process, ProcessIdentity(
            pid: process.processIdentifier,
            startedAt: time_t(bsd.pbi_start_tvsec),
            uid: bsd.pbi_uid,
            name: "sleep",
            executablePath: arguments[0],
            arguments: ProcessDetails.arguments(of: process.processIdentifier),
            workingDirectory: ProcessDetails.workingDirectory(of: process.processIdentifier)))
    }

    @Test("rebuilds a pasteable command with its directory")
    func rebuildsCommand() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let (process, identity) = try spawn(["/bin/sleep", "30"], directory: directory)
        defer { if process.isRunning { process.terminate() } }

        let command = try #require(StartCommand(for: identity))
        #expect(command.shellCommand.contains("/bin/sleep 30"))
        #expect(command.shellCommand.hasPrefix("cd "))
    }

    @Test("quotes anything a shell would misread")
    func quotesUnsafeArguments() {
        // A path with a space silently becomes two arguments otherwise.
        #expect(StartCommand.quoted("/Users/me/My Project") == "'/Users/me/My Project'")
        #expect(StartCommand.quoted("--port=3000") == "--port=3000")
        #expect(StartCommand.quoted("it's") == #"'it'\''s'"#)
        #expect(StartCommand.quoted("") == "''")
    }

    @Test("another user's process yields nothing")
    func foreignProcessHasNoCommand() {
        let foreign = ProcessIdentity(
            pid: 1, startedAt: nil, uid: 0, name: "launchd", executablePath: "/sbin/launchd")
        #expect(StartCommand(for: foreign) == nil)
    }

    /// Documents a platform limit rather than a bug, so that nobody
    /// reintroduces a Restart feature believing this works.
    @Test("macOS no longer exposes a process environment")
    func environmentIsUnavailable() throws {
        let (process, identity) = try spawn(["/bin/sleep", "30"])
        defer { if process.isRunning { process.terminate() } }

        let commandLine = try #require(ProcessDetails.commandLine(of: identity.pid))
        #expect(!commandLine.arguments.isEmpty)
        #expect(commandLine.environment.isEmpty,
                "if this ever fails, macOS exposes environments again and a faithful Restart becomes possible")
    }
}
