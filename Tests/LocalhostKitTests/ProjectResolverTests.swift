import Foundation
import Testing
@testable import LocalhostKit

@Suite("ProjectResolver")
struct ProjectResolverTests {
    /// Builds a throwaway tree and hands back its root.
    private func tree(_ files: [String: String], directories: [String] = []) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localhost-tests-\(UUID().uuidString)")
        for directory in directories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for (path, contents) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        return root
    }

    private let resolver = ProjectResolver()

    @Test("finds a package.json name from deep inside the tree")
    func packageJSONFromNestedDirectory() throws {
        let root = try tree(
            ["package.json": #"{"name": "acme-dashboard"}"#],
            directories: ["src/components/deep"])
        let project = try #require(resolver.project(
            for: root.appendingPathComponent("src/components/deep").path))
        #expect(project.name == "acme-dashboard")
        #expect(project.source == .packageJSON)
    }

    @Test("the nearest marker wins over an outer one")
    func nearestMarkerWins() throws {
        let root = try tree([
            "package.json": #"{"name": "outer-monorepo"}"#,
            "packages/inner/package.json": #"{"name": "inner-app"}"#,
        ])
        let project = try #require(resolver.project(
            for: root.appendingPathComponent("packages/inner").path))
        #expect(project.name == "inner-app")
    }

    @Test("a package.json with no name is not a hit, so the walk continues")
    func packageJSONWithoutNameContinuesUpwards() throws {
        // Private workspace packages routinely omit `name`. The design says
        // "package.json -> its name field" and "first hit wins", so a file
        // without a name is not a hit and the walk carries on to the monorepo
        // root. The label is a real ancestor's name, never an invented one.
        //
        // Open question for the brief: in a monorepo, is "acme" the right label
        // for a server running in acme/apps/web, or should the row prefer the
        // directory name "web"? Both are honest; this asserts the documented one.
        let root = try tree([
            "package.json": #"{"name": "outer"}"#,
            "app/package.json": #"{"private": true}"#,
        ])
        let project = try #require(resolver.project(for: root.appendingPathComponent("app").path))
        #expect(project.name == "outer")
    }

    @Test("malformed package.json does not crash or mislabel")
    func malformedPackageJSON() throws {
        let root = try tree(["package.json": "{ this is not json"])
        #expect(resolver.project(for: root.path) == nil)
    }

    @Test("reads Cargo.toml", arguments: [
        ("Cargo.toml", "[package]\nname = \"ferris-api\"\nversion = \"0.1.0\"\n", "ferris-api"),
        ("pyproject.toml", "[project]\nname = \"snake-service\"\n", "snake-service"),
    ])
    func tomlMarkers(file: String, contents: String, expected: String) throws {
        let root = try tree([file: contents])
        let project = try #require(resolver.project(for: root.path))
        #expect(project.name == expected)
    }

    @Test("a name outside the package table is not picked up")
    func tomlNameInWrongTableIsIgnored() throws {
        let root = try tree(["Cargo.toml": "[dependencies]\nname = \"serde\"\n"])
        #expect(resolver.project(for: root.path) == nil)
    }

    @Test("go.mod reduces a module path to its last component")
    func goModuleName() throws {
        let root = try tree(["go.mod": "module github.com/magnisoft/gopher-tool\n\ngo 1.22\n"])
        let project = try #require(resolver.project(for: root.path))
        #expect(project.name == "gopher-tool")
        #expect(project.source == .goModule)
    }

    @Test("falls back to the directory name for a bare git checkout")
    func gitFallback() throws {
        let root = try tree([:], directories: ["my-checkout/.git", "my-checkout/src"])
        let project = try #require(resolver.project(
            for: root.appendingPathComponent("my-checkout/src").path))
        #expect(project.name == "my-checkout")
        #expect(project.source == .git)
    }

    @Test("a .git file, as used by worktrees and submodules, still counts")
    func gitWorktreeFile() throws {
        let root = try tree(["work/.git": "gitdir: /elsewhere/.git/worktrees/work\n"])
        let project = try #require(resolver.project(for: root.appendingPathComponent("work").path))
        #expect(project.name == "work")
    }

    @Test("package.json beats an adjacent .git")
    func markerOrderIsRespected() throws {
        let root = try tree(
            ["thing/package.json": #"{"name": "the-real-name"}"#],
            directories: ["thing/.git"])
        let project = try #require(resolver.project(for: root.appendingPathComponent("thing").path))
        #expect(project.name == "the-real-name")
        #expect(project.source == .packageJSON)
    }

    @Test("unmarked directories resolve to nothing")
    func noMarkersYieldsNil() throws {
        let root = try tree([:], directories: ["nothing/here"])
        #expect(resolver.project(for: root.appendingPathComponent("nothing/here").path) == nil)
    }

    @Test("hostile inputs are handled", arguments: ["", "/", "/nonexistent-\(UUID().uuidString)"])
    func hostileInputs(path: String) {
        #expect(resolver.project(for: path) == nil)
    }

    @Test("the walk is bounded")
    func walkIsBounded() throws {
        let deep = (0..<200).map { "d\($0)" }.joined(separator: "/")
        let root = try tree(["package.json": #"{"name": "far-away"}"#], directories: [deep])
        // Beyond the depth limit the answer is nothing, never a hang.
        #expect(resolver.project(for: root.appendingPathComponent(deep).path) == nil)
    }
}

@Suite("KnownDaemons")
struct KnownDaemonsTests {
    @Test("explains AirPlay on 5000")
    func airplayIsExplained() throws {
        let daemon = try #require(KnownDaemons.daemon(port: 5000, processName: "ControlCenter"))
        #expect(daemon.label == "AirPlay Receiver")
        #expect(daemon.advice != nil)
    }

    @Test("explains a launchd-held Screen Sharing socket")
    func launchdHeldSocketIsExplained() throws {
        // The whole reason this table exists: attribution can only say "launchd".
        let daemon = try #require(KnownDaemons.daemon(port: 5900, processName: "launchd"))
        #expect(daemon.label == "Screen Sharing")
    }

    @Test("does not claim your own dev server on 5000 is AirPlay")
    func portAloneIsNotEnough() {
        #expect(KnownDaemons.daemon(port: 5000, processName: "python3") == nil)
        #expect(KnownDaemons.daemon(port: 5000, processName: "node") == nil)
    }

    @Test("says nothing about ordinary ports")
    func unknownPortsAreUnlabelled() {
        #expect(KnownDaemons.daemon(port: 3000, processName: "node") == nil)
    }
}

@Suite("Attribution")
struct AttributionTests {
    private func listener(
        port: UInt16, name: String, cwd: String?, ours: Bool = true
    ) -> Listener {
        Listener(
            port: port,
            addresses: ["127.0.0.1"],
            families: [.ipv4],
            process: ProcessIdentity(
                pid: 1234,
                startedAt: ours ? 1 : nil,
                uid: ours ? getuid() : 0,
                name: name,
                workingDirectory: cwd))
    }

    @Test("a known daemon is explained even though it has no project")
    func daemonBeatsAbsentProject() {
        let rows = ListenerAttributor().present([
            listener(port: 5900, name: "launchd", cwd: "/"),
        ])
        #expect(rows.first?.label == "Screen Sharing")
        #expect(rows.first?.advice != nil)
    }

    @Test("a process we cannot read is marked unavailable, not empty")
    func otherUsersProcessIsUnavailable() {
        let rows = ListenerAttributor().present([
            listener(port: 9999, name: "mysteryd", cwd: nil, ours: false),
        ])
        #expect(rows.first?.attribution == .unavailable)
        #expect(rows.first?.label == nil)
    }

    @Test("our own process with no marker is nothing, not unavailable")
    func ourProcessWithoutMarkerIsNothing() {
        let rows = ListenerAttributor().present([
            listener(port: 9999, name: "node", cwd: "/"),
        ])
        #expect(rows.first?.attribution == .nothing)
    }

    @Test("never labels a row it cannot justify")
    func neverInventsALabel() {
        let rows = ListenerAttributor().present([
            listener(port: 3000, name: "node", cwd: "/definitely/not/a/real/path"),
        ])
        #expect(rows.first?.label == nil)
    }
}

@Suite("Prominence")
struct ProminenceTests {
    private func row(port: UInt16, name: String, cwd: String?) -> Listener {
        Listener(
            port: port,
            addresses: ["127.0.0.1"],
            families: [.ipv4],
            process: ProcessIdentity(
                pid: 10, startedAt: 1, uid: getuid(), name: name, workingDirectory: cwd))
    }

    @Test("a daemon on a random high port folds away")
    func highPortDaemonIsBackground() {
        let rows = ListenerAttributor().present([row(port: 55778, name: "rapportd", cwd: "/")])
        #expect(rows.first?.prominence == .background)
    }

    @Test("a port a person would choose stays listed", arguments: [80, 443, 3000, 5432, 8080] as [UInt16])
    func chosenPortsAreListed(port: UInt16) {
        let rows = ListenerAttributor().present([row(port: port, name: "node", cwd: "/")])
        #expect(rows.first?.prominence == .listed)
    }

    @Test("a resolved project is listed whatever the port")
    func projectAlwaysWinsOverPortNumber() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prominence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"{"name": "late-bound"}"#
            .write(to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let rows = ListenerAttributor().present([row(port: 61330, name: "node", cwd: directory.path)])
        #expect(rows.first?.label == "late-bound")
        #expect(rows.first?.prominence == .listed, "a project must never be folded away")
    }

    @Test("a known daemon on a high port is still listed")
    func knownDaemonIsListed() {
        // Not currently reachable via the table, but the rule must not depend
        // on the port for something we can actually explain.
        let rows = ListenerAttributor().present([row(port: 5900, name: "launchd", cwd: "/")])
        #expect(rows.first?.prominence == .listed)
    }
}
