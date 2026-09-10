import Darwin
import Foundation

// pcblist_n: variable-length tagged records. Structs are XNU-private, so we
// read fields at fixed byte offsets and VALIDATE the parse against libproc.
let XSO_SOCKET: UInt32 = 0x001, XSO_INPCB: UInt32 = 0x010, XSO_TCPCB: UInt32 = 0x020

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func fmt4(_ a: in_addr) -> String { var a = a; var o = [CChar](repeating: 0, count: 16); inet_ntop(AF_INET, &a, &o, 16); return String(cString: o) }
func fmt6(_ a: in6_addr) -> String { var a = a; var o = [CChar](repeating: 0, count: 46); inet_ntop(AF_INET6, &a, &o, 46); return String(cString: o) }

struct NRow { var port: UInt16 = 0; var addr = ""; var v4 = true; var uid: uid_t = 0; var lastPid: pid_t = 0; var state: Int32 = -1 }

func scanPcblistN() -> ([NRow], [String]) {
    var notes: [String] = []
    var size = 0
    guard sysctlbyname("net.inet.tcp.pcblist_n", nil, &size, nil, 0) == 0 else { return ([], ["size probe failed: \(String(cString: strerror(errno)))"]) }
    var buf = [UInt8](repeating: 0, count: size + 16384)
    size = buf.count
    guard sysctlbyname("net.inet.tcp.pcblist_n", &buf, &size, nil, 0) == 0 else { return ([], ["fetch failed: \(String(cString: strerror(errno)))"]) }

    var rows: [NRow] = []
    var lens: Set<String> = []
    buf.withUnsafeBytes { raw in
        var off = Int(raw.loadUnaligned(as: UInt32.self))   // skip leading xinpgen
        var cur = NRow()
        var haveInp = false
        while off + 8 <= size {
            let len = Int(raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))
            let kind = raw.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self)
            if len < 8 { break }
            lens.insert("kind=0x\(String(kind, radix: 16)) len=\(len)")
            switch kind {
            case XSO_INPCB:
                if haveInp { rows.append(cur) }          // flush previous group
                cur = NRow(); haveInp = true
                cur.port = UInt16(bigEndian: raw.loadUnaligned(fromByteOffset: off + 18, as: UInt16.self))
                cur.v4 = (raw.loadUnaligned(fromByteOffset: off + 44, as: UInt8.self) & 0x1) != 0   // inp_vflag
                cur.addr = cur.v4 ? fmt4(raw.loadUnaligned(fromByteOffset: off + 76, as: in_addr.self))       // inp_dependladdr +12
                                  : fmt6(raw.loadUnaligned(fromByteOffset: off + 64, as: in6_addr.self))
            case XSO_SOCKET:
                cur.uid     = raw.loadUnaligned(fromByteOffset: off + 64, as: uid_t.self)     // so_uid
                cur.lastPid = raw.loadUnaligned(fromByteOffset: off + 68, as: pid_t.self)     // so_last_pid
            case XSO_TCPCB:
                cur.state   = raw.loadUnaligned(fromByteOffset: off + 8 + 8 + 4 + 4 * 4      /* TCPT_NTIMERS_EXT=4 */, as: Int32.self)
            default: break
            }
            off += (len + 7) & ~7      // records are 8-byte aligned
        }
        if haveInp { rows.append(cur) }
    }
    notes.append("record kinds/lengths seen: " + lens.sorted().joined(separator: ", "))
    return (rows, notes)
}

// ─── ground truth from libproc, to validate the offset guesses ───────────────
func libprocListeners() -> [String: pid_t] {
    var out: [String: pid_t] = [:]
    let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(n) / MemoryLayout<pid_t>.size + 32)
    let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    let sockSize = Int32(MemoryLayout<socket_fdinfo>.size)
    for pid in pids.prefix(Int(got) / MemoryLayout<pid_t>.size) where pid > 0 {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { continue }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 16)
        let g = fds.withUnsafeMutableBufferPointer { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count * MemoryLayout<proc_fdinfo>.size)) }
        guard g > 0 else { continue }
        for fd in fds.prefix(Int(g) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            guard withUnsafeMutablePointer(to: &si, { proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, $0, sockSize) }) == sockSize,
                  si.psi.soi_kind == SOCKINFO_TCP else { continue }
            let t = si.psi.soi_proto.pri_tcp
            guard t.tcpsi_state == TSI_S_LISTEN else { continue }
            out["\(UInt16(bigEndian: UInt16(truncatingIfNeeded: t.tcpsi_ini.insi_lport)))"] = pid
        }
    }
    return out
}

let me = getuid()
var times: [Double] = []
var rows: [NRow] = []; var notes: [String] = []
for _ in 0..<7 { let t = now(); (rows, notes) = scanPcblistN(); times.append(now() - t) }
times.sort()
print("=== pcblist_n (hand-parsed offsets) ===")
print(String(format: "scan: median=%.2fms   records=%d", times[times.count/2] * 1000, rows.count))
for n in notes { print(n) }

let listening = rows.filter { $0.state == TCPS_LISTEN }
print("\nLISTEN rows: \(listening.count)")

let truth = libprocListeners()
print("\n--- VALIDATION: so_last_pid vs libproc ground truth (same-user listeners) ---")
var match = 0, mismatch = 0
for r in listening where r.uid == me {
    guard let real = truth["\(r.port)"] else { continue }
    if r.lastPid == real { match += 1 }
    else { mismatch += 1; print("  MISMATCH port \(r.port): pcblist_n says pid \(r.lastPid), libproc says \(real)") }
}
print("  matched=\(match)  mismatched=\(mismatch)")

print("\n--- root-owned listeners, now with a name ---")
for r in listening.filter({ $0.uid != me }).sorted(by: { $0.port < $1.port }) {
    var pbuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let ok = proc_pidpath(r.lastPid, &pbuf, UInt32(pbuf.count)) > 0
    let name = ok ? String(cString: pbuf) : "<no path>"
    print(String(format: "  %5d  %-22s uid=%d  last_pid=%-6d  %@", Int(r.port), (r.addr as NSString).utf8String!, Int(r.uid), Int(r.lastPid), name))
}
