import Foundation

/// The branch checked out at a project root.
///
/// `ProjectResolver` already located the root, so this is one small file read.
/// It earns its place when two worktrees of the same repository are both
/// running: "campo" twice tells you nothing, "campo · main" and
/// "campo · feature/checkout" tell you which window to go to.
public enum GitBranch {
    public static func branch(at root: URL) -> String? {
        guard let head = headFile(for: root),
              let contents = try? String(contentsOf: head, encoding: .utf8)
        else { return nil }

        let text = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "ref: refs/heads/") {
            let branch = String(text[range.upperBound...])
            return branch.isEmpty ? nil : branch
        }
        // Detached HEAD holds a bare object id; a short one reads better.
        guard text.count >= 7, text.allSatisfy(\.isHexDigit) else { return nil }
        return String(text.prefix(7))
    }

    /// `.git` is a directory in a normal checkout and a file pointing elsewhere
    /// in a worktree or submodule.
    private static func headFile(for root: URL) -> URL? {
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory)
        else { return nil }

        if isDirectory.boolValue {
            return dotGit.appendingPathComponent("HEAD")
        }
        guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
              let range = pointer.range(of: "gitdir:")
        else { return nil }
        let path = pointer[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).appendingPathComponent("HEAD")
    }
}
