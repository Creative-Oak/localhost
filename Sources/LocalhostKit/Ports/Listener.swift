import Darwin
import Foundation

public enum Family: String, Sendable, Hashable, CaseIterable {
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"
}

/// Identity of the process behind a listener.
///
/// `startedAt` is deliberately optional and is the reason this type exists.
/// Between the scan that draws a row and the click that acts on it, a process
/// can exit and its PID be recycled; `(pid, startedAt)` is the stable identity
/// that a terminator must re-verify before signalling.
///
/// It is `nil` exactly when we could not read the process table entry — which
/// on macOS means the process belongs to another user. Those processes are not
/// ours to signal, so the rule is enforced by the type: **no `startedAt`, no
/// kill.**
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: pid_t
    public let startedAt: time_t?
    public let uid: uid_t
    public let name: String
    public let executablePath: String?
    public let arguments: [String]?
    public let workingDirectory: String?

    public init(
        pid: pid_t,
        startedAt: time_t?,
        uid: uid_t,
        name: String,
        executablePath: String? = nil,
        arguments: [String]? = nil,
        workingDirectory: String? = nil
    ) {
        self.pid = pid
        self.startedAt = startedAt
        self.uid = uid
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    /// Whether this process is ours to inspect fully and, later, to signal.
    public var isOurs: Bool { startedAt != nil }
}

public struct Listener: Identifiable, Hashable, Sendable {
    public let port: UInt16
    /// Every address this port was found bound to, deduplicated. One server
    /// usually binds both IPv4 and IPv6, and sometimes several addresses.
    public let addresses: [String]
    public let families: Set<Family>
    public let process: ProcessIdentity

    /// Dedup key: one row per process per port, however many addresses it bound.
    public struct ID: Hashable, Sendable {
        public let pid: pid_t
        public let port: UInt16
    }
    public var id: ID { ID(pid: process.pid, port: port) }

    public init(port: UInt16, addresses: [String], families: Set<Family>, process: ProcessIdentity) {
        self.port = port
        self.addresses = addresses
        self.families = families
        self.process = process
    }

    /// True when bound to a wildcard address, i.e. reachable from the network
    /// rather than only from this machine.
    public var isExposed: Bool {
        addresses.contains { $0 == "0.0.0.0" || $0 == "::" }
    }
}

/// One socket as a scanner reports it, before attribution or deduplication.
public struct RawListener: Hashable, Sendable {
    public let port: UInt16
    public let address: String
    public let family: Family
    public let pid: pid_t
    public let uid: uid_t

    public init(port: UInt16, address: String, family: Family, pid: pid_t, uid: uid_t) {
        self.port = port
        self.address = address
        self.family = family
        self.pid = pid
        self.uid = uid
    }
}
