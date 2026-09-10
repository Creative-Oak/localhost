import Darwin
import Foundation

public enum ScanError: Error, Sendable, CustomStringConvertible {
    case sysctlFailed(name: String, errno: Int32)

    public var description: String {
        switch self {
        case let .sysctlFailed(name, code):
            return "sysctl \(name) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// The discovery spine: every TCP listener on the machine, whoever owns it.
///
/// Unprivileged, and roughly 0.5 ms for a full scan. Unlike libproc it is not
/// restricted to the current user's processes, which is the only reason
/// root-owned listeners such as Screen Sharing on 5900 appear at all.
///
/// Two sources, because they trade coverage against durability:
///
/// - ``Source/pcblistN`` reads `xinpcb_n` / `xsocket_n` / `xtcpcb_n`. These are
///   XNU-private, so the field offsets below were recovered by hexdumping
///   against a socket of known port, address, PID and UID rather than taken
///   from a header. They carry `so_last_pid`, so every row gets a process.
/// - ``Source/pcblist64`` reads `xtcpcb64`, which is public SDK API and cannot
///   drift. It has `so_uid` but no PID, so rows survive without a name.
///
/// `PcbListScanner` never decides which to use. ``ScanOracle`` does, by
/// checking the private parse against libproc on every scan.
public struct PcbListScanner: Sendable {
    public enum Source: String, Sendable {
        case pcblistN = "net.inet.tcp.pcblist_n"
        case pcblist64 = "net.inet.tcp.pcblist64"
    }

    public let source: Source

    public init(source: Source = .pcblistN) {
        self.source = source
    }

    public func scan() throws -> [RawListener] {
        let buffer = try fetch(source.rawValue)
        switch source {
        case .pcblistN: return parsePcblistN(buffer)
        case .pcblist64: return parsePcblist64(buffer)
        }
    }

    // MARK: - Fetch

    private func fetch(_ name: String) throws -> [UInt8] {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else {
            throw ScanError.sysctlFailed(name: name, errno: errno)
        }
        // Sockets can appear between the size probe and the fetch, so ask for
        // headroom rather than racing.
        var buffer = [UInt8](repeating: 0, count: size + 64 * 1024)
        size = buffer.count
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            throw ScanError.sysctlFailed(name: name, errno: errno)
        }
        return Array(buffer[0..<size])
    }

    // MARK: - pcblist_n, hand-parsed

    // Record tags, from <sys/socketvar.h>.
    private static let kindSocket: UInt32 = 0x001
    private static let kindInpcb: UInt32 = 0x010
    private static let kindTcpcb: UInt32 = 0x020

    // Offsets recovered by hexdump; see docs/spike-findings.md. Changing these
    // without re-deriving them against a known socket will silently misattribute.
    private enum Offset {
        static let inpLocalPort = 18   // u16, network byte order
        static let inpVFlag = 44       // u8, INP_IPV4 / INP_IPV6
        static let inpLocalAddr = 64   // union; IPv4 sits 12 bytes in
        static let inpLocalAddr4 = 76
        static let soUID = 64          // uid_t
        static let soLastPID = 68      // pid_t
        static let tcpState = 36       // int, after TCPT_NTIMERS_EXT == 4 timers
    }

    private func parsePcblistN(_ buffer: [UInt8]) -> [RawListener] {
        buffer.withUnsafeBytes { raw -> [RawListener] in
            let size = raw.count
            guard size > MemoryLayout<UInt32>.size else { return [] }

            var rows: [RawListener] = []
            var offset = Int(raw.loadUnaligned(as: UInt32.self))   // skip leading xinpgen

            // Fields arrive as a tagged sequence per socket, not as one struct.
            var port: UInt16 = 0
            var address = ""
            var family = Family.ipv4
            var uid: uid_t = 0
            var pid: pid_t = 0
            var state: Int32 = -1
            var open = false

            func flush() {
                guard open, state == TCPS_LISTEN else { return }
                rows.append(RawListener(port: port, address: address, family: family, pid: pid, uid: uid))
            }

            while offset + 8 <= size {
                let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let kind = raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
                guard length >= 8, offset + length <= size else { break }

                switch kind {
                case Self.kindInpcb:
                    flush()                       // a new PCB closes the previous one
                    open = true
                    state = -1
                    port = UInt16(bigEndian: raw.loadUnaligned(
                        fromByteOffset: offset + Offset.inpLocalPort, as: UInt16.self))
                    let isIPv4 = raw.loadUnaligned(
                        fromByteOffset: offset + Offset.inpVFlag, as: UInt8.self) & UInt8(INP_IPV4) != 0
                    family = isIPv4 ? .ipv4 : .ipv6
                    address = isIPv4
                        ? SocketAddress.string(raw.loadUnaligned(fromByteOffset: offset + Offset.inpLocalAddr4, as: in_addr.self))
                        : SocketAddress.string(raw.loadUnaligned(fromByteOffset: offset + Offset.inpLocalAddr, as: in6_addr.self))
                case Self.kindSocket:
                    uid = raw.loadUnaligned(fromByteOffset: offset + Offset.soUID, as: uid_t.self)
                    pid = raw.loadUnaligned(fromByteOffset: offset + Offset.soLastPID, as: pid_t.self)
                case Self.kindTcpcb:
                    state = raw.loadUnaligned(fromByteOffset: offset + Offset.tcpState, as: Int32.self)
                default:
                    break
                }

                // Records are 8-byte aligned. Advancing by `length` alone stops
                // the walk after the first socket, because the 204-byte TCPCB
                // record pads to 208.
                offset += (length + 7) & ~7
            }
            flush()
            return rows
        }
    }

    // MARK: - pcblist64, public structs

    private func parsePcblist64(_ buffer: [UInt8]) -> [RawListener] {
        buffer.withUnsafeBytes { raw -> [RawListener] in
            let size = raw.count
            guard size > MemoryLayout<xinpgen>.size else { return [] }

            var rows: [RawListener] = []
            var offset = Int(raw.loadUnaligned(as: xinpgen.self).xig_len)
            let record = MemoryLayout<xtcpcb64>.size

            while offset + MemoryLayout<xinpgen>.size <= size {
                let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                guard length > MemoryLayout<xinpgen>.size, offset + record <= size else { break }

                let tcp = raw.loadUnaligned(fromByteOffset: offset, as: xtcpcb64.self)
                defer { offset += length }
                guard tcp.t_state == TCPS_LISTEN else { continue }

                let inp = tcp.xt_inpcb
                let isIPv4 = inp.inp_vflag & UInt8(INP_IPV4) != 0
                rows.append(RawListener(
                    port: UInt16(bigEndian: inp.inp_lport),
                    address: isIPv4
                        ? SocketAddress.string(inp.inp_dependladdr.inp46_local.ia46_addr4)
                        : SocketAddress.string(inp.inp_dependladdr.inp6_local),
                    family: isIPv4 ? .ipv4 : .ipv6,
                    pid: 0,                        // not carried by the public struct
                    uid: inp.xi_socket.so_uid))
            }
            return rows
        }
    }

}
