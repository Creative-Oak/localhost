import Darwin
import Foundation

/// Signals a process, and refuses to unless it is provably still the same one.
///
/// Between the scan that drew a row and the click that acts on it, the process
/// can exit and its pid be recycled onto something else. Killing the wrong
/// process because of a stale row is the worst thing this app could do, so the
/// pid alone is never sufficient: `(pid, startedAt)` is re-read immediately
/// before signalling and must match what the row was built from.
///
/// This type cannot find a listener. It re-reads one process by pid to verify
/// identity, and that is the whole of its access to the system.
public struct ProcessTerminator: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Another user's process. We never had the right to signal it, and it
        /// carries no start time to verify against.
        case notPermitted
        /// Gone between the scan and the click. Nothing to do, and not an error
        /// worth alarming anyone about.
        case alreadyExited
        /// The pid is alive but is no longer the process the row described.
        /// This is the case the whole type exists for.
        case identityChanged(expected: time_t, found: time_t)
        case signalFailed(code: Int32)

        public var description: String {
            switch self {
            case .notPermitted:
                return "That process belongs to another user."
            case .alreadyExited:
                return "That process had already exited."
            case .identityChanged:
                return "That process ID now belongs to something else. Nothing was signalled."
            case let .signalFailed(code):
                return "Could not signal the process: \(String(cString: strerror(code)))."
            }
        }
    }

    public enum Signal: Sendable {
        /// Ask it to stop, which lets a dev server tear down cleanly.
        case terminate
        /// Insist, for something that ignored the first request.
        case force

        var rawValue: Int32 {
            switch self {
            case .terminate: return SIGTERM
            case .force: return SIGKILL
            }
        }
    }

    public init() {}

    public func terminate(_ identity: ProcessIdentity, using signal: Signal = .terminate) throws {
        // No start time means we could not read the process table entry, which
        // means it is not ours. The type system carried this all the way here.
        guard let expected = identity.startedAt else { throw Failure.notPermitted }

        guard let current = ProcessDetails.bsdInfo(of: identity.pid) else {
            throw Failure.alreadyExited
        }

        let found = time_t(current.pbi_start_tvsec)
        guard found == expected else {
            throw Failure.identityChanged(expected: expected, found: found)
        }
        // Re-checked rather than trusted from the row: ownership at scan time
        // is not ownership now.
        guard current.pbi_uid == getuid() else { throw Failure.notPermitted }

        guard Darwin.kill(identity.pid, signal.rawValue) == 0 else {
            throw errno == ESRCH ? Failure.alreadyExited : Failure.signalFailed(code: errno)
        }
    }
}
