import Foundation

/// Turns a working directory into the name a developer would recognise.
///
/// A pure function of the file system: no caching, no state, no guessing. If
/// nothing matches, it returns `nil` and the caller shows the process name
/// instead. **It never invents a label.**
public struct ProjectResolver: Sendable {
    /// How a label was arrived at, so the interface can be honest about it.
    public enum Source: String, Sendable, Hashable {
        case packageJSON = "package.json"
        case cargo = "Cargo.toml"
        case pyproject = "pyproject.toml"
        case goModule = "go.mod"
        case git = "git"
    }

    public struct Project: Hashable, Sendable {
        public let name: String
        public let root: URL
        public let source: Source
    }

    /// Stops a symlink loop or a pathological tree from walking forever.
    private let maximumDepth: Int

    public init(maximumDepth: Int = 24) {
        self.maximumDepth = maximumDepth
    }

    public func project(for workingDirectory: String) -> Project? {
        guard !workingDirectory.isEmpty else { return nil }
        var directory = URL(fileURLWithPath: workingDirectory).standardizedFileURL

        for _ in 0..<maximumDepth {
            if let project = self.project(in: directory) { return project }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            // "/" is nobody's project, and its parent is itself.
            if parent.path == directory.path || directory.path == "/" { return nil }
            directory = parent
        }
        return nil
    }

    /// First hit wins, in the order a developer would expect.
    private func project(in directory: URL) -> Project? {
        if let name = packageJSONName(in: directory) {
            return Project(name: name, root: directory, source: .packageJSON)
        }
        if let name = tomlName(in: directory, file: "Cargo.toml", table: "package") {
            return Project(name: name, root: directory, source: .cargo)
        }
        if let name = tomlName(in: directory, file: "pyproject.toml", table: "project") {
            return Project(name: name, root: directory, source: .pyproject)
        }
        if let name = goModuleName(in: directory) {
            return Project(name: name, root: directory, source: .goModule)
        }
        // A .git entry is a directory in a normal checkout and a file in a
        // worktree or submodule, so test for existence rather than for a directory.
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            let name = directory.lastPathComponent
            return name.isEmpty ? nil : Project(name: name, root: directory, source: .git)
        }
        return nil
    }

    // MARK: - Markers

    private func contents(of directory: URL, _ file: String) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
    }

    /// A `package.json` with no `name` is common in workspace roots and private
    /// apps. It is a marker without a label, so the walk stops and yields nothing
    /// rather than continuing up into an unrelated parent project.
    private func packageJSONName(in directory: URL) -> String? {
        guard let text = contents(of: directory, "package.json"),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let name = object["name"] as? String, !name.isEmpty else { return nil }
        return name
    }

    /// Deliberately not a TOML parser: find the table, take its `name` key.
    /// Enough for `Cargo.toml` and `pyproject.toml`, and it fails to `nil`.
    private func tomlName(in directory: URL, file: String, table: String) -> String? {
        guard let text = contents(of: directory, file) else { return nil }
        var inTable = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inTable = (line == "[\(table)]")
                continue
            }
            guard inTable, line.hasPrefix("name") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// `module github.com/owner/thing` reads best as `thing`.
    private func goModuleName(in directory: URL) -> String? {
        guard let text = contents(of: directory, "go.mod") else { return nil }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("module ") else { continue }
            let path = line.dropFirst("module ".count).trimmingCharacters(in: .whitespaces)
            guard let last = path.split(separator: "/").last, !last.isEmpty else { continue }
            return String(last)
        }
        return nil
    }
}
