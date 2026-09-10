import Darwin
import Foundation

public protocol PortScanning: Sendable {
    func scan() -> ScanResult
}

/// Whether the private-struct parse could be trusted on this scan.
public enum OracleStatus: Hashable, Sendable {
    /// `pcblist_n` and libproc agreed on every listener they both saw.
    case verified(matched: Int)
    /// They disagreed, or `pcblist_n` was unavailable. The scan fell back to
    /// the public `pcblist64` structs: rows still appear, but listeners we do
    /// not own lose their process.
    case degraded(reason: String)
    /// Neither source could be read.
    case failed(reason: String)

    public var isTrustworthy: Bool {
        if case .verified = self { return true }
        return false
    }
}

public struct ScanResult: Sendable {
    public let listeners: [Listener]
    public let oracle: OracleStatus
    public let duration: Duration

    public init(listeners: [Listener], oracle: OracleStatus, duration: Duration) {
        self.listeners = listeners
        self.oracle = oracle
        self.duration = duration
    }
}

/// Composes the two scanners into the rows the interface draws.
///
/// `pcblist_n` supplies the rows because it is the only unprivileged source
/// that sees every listener. libproc supplies attribution — and, on every
/// single scan, verifies the private-struct parse that `pcblist_n` depends on.
/// The check is nearly free: libproc has to run anyway.
///
/// This type can discover and describe. It has no way to signal a process.
public struct ListenerScanner: PortScanning {
    private let privateScanner: PcbListScanner
    private let publicScanner: PcbListScanner
    private let libproc: LibprocScanner
    private let details: ProcessDetails

    public init(
        privateScanner: PcbListScanner = PcbListScanner(source: .pcblistN),
        publicScanner: PcbListScanner = PcbListScanner(source: .pcblist64),
        libproc: LibprocScanner = LibprocScanner(),
        details: ProcessDetails = ProcessDetails()
    ) {
        self.privateScanner = privateScanner
        self.publicScanner = publicScanner
        self.libproc = libproc
        self.details = details
    }

    public func scan() -> ScanResult {
        // Scanning creates a great many short-lived Foundation and Objective-C
        // objects. Off the main thread there is no run loop to drain them, so
        // without an explicit pool the footprint grows about 22KB per scan —
        // roughly 39MB per hour with the menu open. Measured, not assumed:
        // 1000 scans drift +21.6MB unpooled and +0.2MB pooled.
        autoreleasepool { scanning(started: ContinuousClock.now) }
    }

    private func scanning(started: ContinuousClock.Instant) -> ScanResult {
        let truth = libproc.scan()

        let (rows, oracle): ([RawListener], OracleStatus)
        do {
            let candidate = try privateScanner.scan()
            switch Self.verify(candidate, against: truth) {
            case let .verified(matched):
                rows = candidate
                oracle = .verified(matched: matched)
            case let .degraded(reason):
                (rows, oracle) = fallback(truth: truth, reason: reason)
            case let .failed(reason):
                (rows, oracle) = fallback(truth: truth, reason: reason)
            }
        } catch {
            (rows, oracle) = fallback(truth: truth, reason: "\(error)")
        }

        return ScanResult(
            listeners: assemble(rows),
            oracle: oracle,
            duration: ContinuousClock.now - started)
    }

    private func fallback(truth: [RawListener], reason: String) -> ([RawListener], OracleStatus) {
        guard let publicRows = try? publicScanner.scan() else {
            // libproc alone still shows the developer their own servers, which
            // is the part of the product that matters most.
            return (truth, .failed(reason: reason))
        }
        // pcblist64 carries no PID, so graft on the ones libproc knows.
        let byEndpoint = Dictionary(
            truth.map { (Endpoint($0), $0.pid) },
            uniquingKeysWith: { first, _ in first })
        let merged = publicRows.map { row in
            RawListener(
                port: row.port,
                address: row.address,
                family: row.family,
                pid: byEndpoint[Endpoint(row)] ?? 0,
                uid: row.uid)
        }
        return (merged, .degraded(reason: reason))
    }

    // MARK: - The oracle

    private struct Endpoint: Hashable {
        let port: UInt16
        let address: String
        let family: Family
        init(_ row: RawListener) {
            port = row.port
            address = row.address
            family = row.family
        }
    }

    /// Decides whether the private-struct parse can be trusted.
    ///
    /// The distinction that matters: a **structurally broken** parse versus a
    /// field that is approximate by design.
    ///
    /// `so_last_pid` is the last process to have touched the socket, not its
    /// owner. For a socket that has been inherited, or handed around, or simply
    /// touched by a sibling process, it legitimately differs from the process
    /// holding the descriptor — and libproc, which derives the pid from the
    /// descriptor itself, is the one that is right. Demanding unanimity here
    /// treated that documented approximation as corruption, and intermittently
    /// threw away every root-owned listener.
    ///
    /// If the offsets really moved, `inp_lport` reads garbage and the endpoints
    /// stop matching libproc's at all — so endpoint overlap is the structural
    /// check. Pid agreement across that overlap is the secondary one, catching
    /// the case where `so_last_pid` alone has shifted.
    static func verify(_ candidate: [RawListener], against truth: [RawListener]) -> OracleStatus {
        guard !truth.isEmpty else {
            // Nothing of our own is listening, so there is nothing to check
            // against. Trusting the parse here would be trusting it unverified.
            return candidate.isEmpty
                ? .verified(matched: 0)
                : .degraded(reason: "no same-user listener available to verify against")
        }

        let expected = Dictionary(
            truth.map { (Endpoint($0), $0.pid) },
            uniquingKeysWith: { first, _ in first })

        var overlapping = 0
        var agreeing = 0
        for row in candidate {
            guard let expectedPID = expected[Endpoint(row)] else { continue }
            overlapping += 1
            if row.pid == expectedPID { agreeing += 1 }
        }

        // Ports themselves did not survive: the layout is wrong.
        guard overlapping > 0 else {
            return .degraded(reason: "none of the \(truth.count) listeners libproc found appear in pcblist_n")
        }

        // A handful of divergences is `so_last_pid` being what it is. Most of
        // them being wrong means the field is no longer where we think it is.
        let agreement = Double(agreeing) / Double(overlapping)
        guard agreement >= Self.minimumPIDAgreement else {
            return .degraded(reason:
                "pcblist_n agreed with libproc on only \(agreeing) of \(overlapping) listeners")
        }
        return .verified(matched: overlapping)
    }

    /// Chosen to sit far from both cases: legitimate `so_last_pid` divergence
    /// affects a small minority of sockets, while a moved offset makes
    /// essentially every pid wrong.
    static let minimumPIDAgreement = 0.5

    // MARK: - Assembly

    /// One row per process per port, however many addresses it bound.
    private func assemble(_ rows: [RawListener]) -> [Listener] {
        var grouped: [Listener.ID: [RawListener]] = [:]
        for row in rows {
            grouped[Listener.ID(pid: row.pid, port: row.port), default: []].append(row)
        }

        var identities: [pid_t: ProcessIdentity] = [:]
        return grouped.values.compactMap { group -> Listener? in
            guard let first = group.first else { return nil }

            let identity: ProcessIdentity
            if let cached = identities[first.pid] {
                identity = cached
            } else {
                identity = details.identity(of: first.pid, fallbackUID: first.uid)
                identities[first.pid] = identity
            }

            // Stable order so the interface does not shuffle between scans.
            let addresses = Array(Set(group.map(\.address))).sorted()
            return Listener(
                port: first.port,
                addresses: addresses,
                families: Set(group.map(\.family)),
                process: identity)
        }
        .sorted { ($0.port, $0.process.pid) < ($1.port, $1.process.pid) }
    }
}
