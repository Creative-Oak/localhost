import Darwin
import Foundation
import Testing
@testable import LocalhostKit

@Suite("Scanners")
struct ScannerTests {
    @Test("libproc finds a real listener and attributes it to this process")
    func libprocFindsRealListener() throws {
        let listener = try TestListener()
        let rows = LibprocScanner().scan()

        let match = rows.first { $0.port == listener.port }
        let found = try #require(match, "libproc did not report port \(listener.port)")
        #expect(found.pid == getpid())
        #expect(found.address == "127.0.0.1")
        #expect(found.family == .ipv4)
    }

    @Test("the sysctl spine finds the same listener")
    func pcblistFindsRealListener() throws {
        let listener = try TestListener()
        let rows = try PcbListScanner(source: .pcblistN).scan()

        let found = try #require(rows.first { $0.port == listener.port })
        #expect(found.pid == getpid())
        #expect(found.uid == getuid())
    }

    @Test("the public-struct fallback finds it too, without a pid")
    func pcblist64FindsRealListener() throws {
        let listener = try TestListener()
        let rows = try PcbListScanner(source: .pcblist64).scan()

        let found = try #require(rows.first { $0.port == listener.port })
        #expect(found.uid == getuid())
        #expect(found.pid == 0, "pcblist64 carries no pid; the scanner must not invent one")
    }

    @Test("a wildcard bind is reported as exposed")
    func wildcardBindIsExposed() throws {
        let listener = try TestListener(loopbackOnly: false)
        let result = ListenerScanner().scan()

        let found = try #require(result.listeners.first { $0.port == listener.port })
        #expect(found.isExposed)
    }

    @Test("a loopback bind is not reported as exposed")
    func loopbackBindIsNotExposed() throws {
        let listener = try TestListener()
        let result = ListenerScanner().scan()

        let found = try #require(result.listeners.first { $0.port == listener.port })
        #expect(!found.isExposed)
    }

    @Test("one row per process per port, however many addresses were bound")
    func rowsAreDeduplicatedByProcessAndPort() throws {
        let listener = try TestListener()
        let result = ListenerScanner().scan()

        let matches = result.listeners.filter { $0.port == listener.port }
        #expect(matches.count == 1)
    }

    @Test("a full scan stays far below the two-second refresh interval")
    func scanIsFast() throws {
        _ = ListenerScanner().scan()                      // warm
        let started = ContinuousClock.now
        _ = ListenerScanner().scan()
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .milliseconds(250), "scan took \(elapsed)")
    }
}

@Suite("Private struct oracle")
struct OracleTests {
    /// The canary for a macOS update moving a field in `xinpcb_n` or
    /// `xsocket_n`. If this fails, the offsets in `PcbListScanner` must be
    /// re-derived against a known socket before the app ships again.
    @Test("pcblist_n agrees with libproc about every listener they both see")
    func privateParseMatchesLibproc() throws {
        let listener = try TestListener()
        let result = ListenerScanner().scan()

        #expect(result.oracle.isTrustworthy, "oracle rejected the parse: \(result.oracle)")
        #expect(result.listeners.contains { $0.port == listener.port })
    }

    @Test("a disagreement degrades rather than being trusted")
    func mismatchIsRejected() {
        let truth = [RawListener(port: 4000, address: "127.0.0.1", family: .ipv4, pid: 42, uid: 501)]
        let wrong = [RawListener(port: 4000, address: "127.0.0.1", family: .ipv4, pid: 99, uid: 501)]

        let status = ListenerScanner.verify(wrong, against: truth)
        #expect(!status.isTrustworthy)
    }

    @Test("agreement on a shared endpoint is accepted")
    func matchIsAccepted() {
        let rows = [RawListener(port: 4000, address: "127.0.0.1", family: .ipv4, pid: 42, uid: 501)]
        #expect(ListenerScanner.verify(rows, against: rows).isTrustworthy)
    }

    @Test("an unverifiable parse is not trusted")
    func unverifiableParseIsRejected() {
        // Rows we cannot check against anything must not be waved through.
        let candidate = [RawListener(port: 80, address: "0.0.0.0", family: .ipv4, pid: 1, uid: 0)]
        #expect(!ListenerScanner.verify(candidate, against: []).isTrustworthy)
    }
}
