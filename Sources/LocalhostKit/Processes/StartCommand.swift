import Darwin
import Foundation

/// Reconstructs how a process was started, as far as macOS will say.
///
/// This began as a Restart feature and could not survive contact with the
/// system. `KERN_PROCARGS2` no longer returns a process's environment on
/// current macOS — `ps -E` shows nothing either, for your own processes as much
/// as anyone's, because environments routinely carry secrets. So a relaunch
/// could reproduce argv and the working directory and would silently drop
/// `PORT=4000 NODE_ENV=development`. A server that comes back on the wrong port
/// while reporting success is the same class of failure as killing the wrong
/// process, so the app does not offer it.
///
/// What it offers instead is the command, to paste into a shell where the
/// environment is whatever the developer's own profile provides. The knowledge
/// is handed over rather than acted on with a piece missing.
public struct StartCommand: Hashable, Sendable {
    public let workingDirectory: String?
    public let arguments: [String]

    public init?(for identity: ProcessIdentity) {
        guard identity.isOurs else { return nil }
        guard let arguments = identity.arguments ?? ProcessDetails.arguments(of: identity.pid),
              !arguments.isEmpty
        else { return nil }
        self.arguments = arguments
        self.workingDirectory = identity.workingDirectory
            ?? ProcessDetails.workingDirectory(of: identity.pid)
    }

    /// A line that can be pasted into a shell.
    public var shellCommand: String {
        let command = arguments.map(Self.quoted).joined(separator: " ")
        guard let workingDirectory, workingDirectory != "/" else { return command }
        return "cd \(Self.quoted(workingDirectory)) && \(command)"
    }

    /// Single-quoted unless it is plainly safe, because argv routinely contains
    /// spaces, and a path with a space silently becomes two arguments.
    static func quoted(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@%+,"))
        guard value.unicodeScalars.allSatisfy(safe.contains), !value.isEmpty else {
            return "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }
        return value
    }
}
