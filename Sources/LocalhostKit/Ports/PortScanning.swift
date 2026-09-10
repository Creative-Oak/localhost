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
        let started = ContinuousClock.now
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

    /// libproc derives a PID from the socket's owning file descriptor, so where
    /// both scanners see the same endpoint they must agree. A single
    /// disagreement means an offset moved and every root-owned row is suspect.
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

        var matched = 0
        for row in candidate {
            guard let expectedPID = expected[Endpoint(row)] else { continue }
            guard row.pid == expectedPID else {
                return .degraded(reason:
                    "pcblist_n reported pid \(row.pid) for port \(row.port), libproc reports \(expectedPID)")
            }
            matched += 1
        }

        guard matched > 0 else {
            return .degraded(reason: "pcblist_n saw none of the \(truth.count) listeners libproc found")
        }
        return .verified(matched: matched)
    }

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
