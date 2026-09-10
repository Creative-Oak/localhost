import Darwin
import Foundation

/// Listeners belonging to the current user, found by walking file descriptors.
///
/// Narrower and slower than ``PcbListScanner`` — it cannot see other users'
/// processes at all — but it derives the PID from the socket's owning file
/// descriptor rather than from a "last PID to touch this socket" hint. That
/// makes it exact, which is what qualifies it as the oracle for the private
/// struct parse in ``ScanOracle``.
public struct LibprocScanner: Sendable {
    public init() {}

    public func scan() -> [RawListener] {
        let uid = getuid()
        var rows: [RawListener] = []
        let socketInfoSize = Int32(MemoryLayout<socket_fdinfo>.size)

        for pid in Self.allPIDs() {
            for descriptor in Self.socketDescriptors(of: pid) {
                var info = socket_fdinfo()
                let read = withUnsafeMutablePointer(to: &info) {
                    proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, $0, socketInfoSize)
                }
                guard read == socketInfoSize, info.psi.soi_kind == SOCKINFO_TCP else { continue }

                let tcp = info.psi.soi_proto.pri_tcp
                guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }

                let endpoint = tcp.tcpsi_ini
                let isIPv4 = endpoint.insi_vflag & UInt8(INI_IPV4) != 0
                rows.append(RawListener(
                    port: UInt16(bigEndian: UInt16(truncatingIfNeeded: endpoint.insi_lport)),
                    address: isIPv4
                        ? SocketAddress.string(endpoint.insi_laddr.ina_46.i46a_addr4)
                        : SocketAddress.string(endpoint.insi_laddr.ina_6),
                    family: isIPv4 ? .ipv4 : .ipv6,
                    pid: pid,
                    uid: uid))
            }
        }
        return rows
    }

    // MARK: - libproc plumbing

    static func allPIDs() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        // Processes can spawn between sizing and reading, so over-allocate.
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
        let read = pids.withUnsafeMutableBufferPointer {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress,
                          Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard read > 0 else { return [] }
        return pids.prefix(Int(read) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// Empty for any process we do not own — `PROC_PIDLISTFDS` is `EPERM` there.
    private static func socketDescriptors(of pid: pid_t) -> [Int32] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 32)
        let read = descriptors.withUnsafeMutableBufferPointer {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress,
                         Int32($0.count * MemoryLayout<proc_fdinfo>.size))
        }
        guard read > 0 else { return [] }
        return descriptors
            .prefix(Int(read) / MemoryLayout<proc_fdinfo>.size)
            .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
            .map(\.proc_fd)
    }

}
