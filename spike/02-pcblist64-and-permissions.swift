import Darwin
import Foundation

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func cStr<T>(_ tuple: T) -> String {
    var t = tuple
    return withUnsafeBytes(of: &t) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
}
func fmt4(_ a: in_addr) -> String { var a = a; var o = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN)); inet_ntop(AF_INET, &a, &o, socklen_t(INET_ADDRSTRLEN)); return String(cString: o) }
func fmt6(_ a: in6_addr) -> String { var a = a; var o = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN)); inet_ntop(AF_INET6, &a, &o, socklen_t(INET6_ADDRSTRLEN)); return String(cString: o) }

// ─── Q: does sysctl pcblist64 see root listeners, from Swift, unprivileged? ───

struct SysRow { let port: UInt16; let addr: String; let uid: uid_t; let v4: Bool }

func scanSysctl() -> [SysRow] {
    var size = 0
    guard sysctlbyname("net.inet.tcp.pcblist64", nil, &size, nil, 0) == 0, size > 0 else { return [] }
    var buf = [UInt8](repeating: 0, count: size + 8192)
    size = buf.count
    guard sysctlbyname("net.inet.tcp.pcblist64", &buf, &size, nil, 0) == 0 else { return [] }

    var rows: [SysRow] = []
    return buf.withUnsafeBytes { raw -> [SysRow] in
        let head = raw.loadUnaligned(as: xinpgen.self)
        var offset = Int(head.xig_len)
        let recordSize = MemoryLayout<xtcpcb64>.size
        while offset + MemoryLayout<xinpgen>.size <= size {
            let gen = raw.loadUnaligned(fromByteOffset: offset, as: xinpgen.self)
            let len = Int(gen.xig_len)
            if len <= MemoryLayout<xinpgen>.size { break }        // trailing xinpgen
            guard offset + recordSize <= size else { break }
            let tcp = raw.loadUnaligned(fromByteOffset: offset, as: xtcpcb64.self)
            defer { offset += len }
            guard tcp.t_state == TCPS_LISTEN else { continue }
            let inp = tcp.xt_inpcb
            let v4 = (inp.inp_vflag & UInt8(INP_IPV4)) != 0
            let addr = v4 ? fmt4(inp.inp_dependladdr.inp46_local.ia46_addr4)
                          : fmt6(inp.inp_dependladdr.inp6_local)
            rows.append(SysRow(port: UInt16(bigEndian: inp.inp_lport),
                               addr: addr, uid: inp.xi_socket.so_uid, v4: v4))
        }
        return rows
    }
}

let me = getuid()
print("=== sysctl pcblist64 from Swift (uid \(me), unprivileged) ===")
var times: [Double] = []
var rows: [SysRow] = []
for _ in 0..<7 { let t = now(); rows = scanSysctl(); times.append(now() - t) }
times.sort()
print(String(format: "scan: min=%.2fms median=%.2fms  LISTEN sockets=%d",
             times[0] * 1000, times[times.count/2] * 1000, rows.count))

let mine = rows.filter { $0.uid == me }
let others = rows.filter { $0.uid != me }
print("owned by me: \(mine.count)   owned by others: \(others.count)\n")
print("--- listeners NOT owned by uid \(me) (libproc and lsof are blind to these) ---")
for r in others.sorted(by: { $0.port < $1.port }) {
    print(String(format: "  %5d  %-24s uid=%d  %@", Int(r.port), (r.addr as NSString).utf8String!, Int(r.uid), r.v4 ? "IPv4" : "IPv6"))
}

// ─── Q4: what exactly happens for processes we cannot enumerate? ──────────────

print("\n=== Q4: per-fact behaviour on processes whose bsdinfo is denied ===")
let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
var pids = [pid_t](repeating: 0, count: Int(n) / MemoryLayout<pid_t>.size + 32)
let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
let all = pids.prefix(Int(got) / MemoryLayout<pid_t>.size).filter { $0 > 0 }

var denied: [pid_t] = []
for pid in all {
    var info = proc_bsdinfo()
    let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
    let r = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, sz) }
    if r != sz { denied.append(pid) }
}
print("processes total=\(all.count)  bsdinfo-denied=\(denied.count)")

var cwdOK = 0, cwdErr: [Int32: Int] = [:]
var argvOK = 0, argvErr: [Int32: Int] = [:]
var pathOK = 0, pathErr: [Int32: Int] = [:]
var argMax: Int32 = 0; var amSize = MemoryLayout<Int32>.size
var amMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
sysctl(&amMib, 2, &argMax, &amSize, nil, 0)

for pid in denied {
    var vpi = proc_vnodepathinfo()
    let vsz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    errno = 0
    let vr = withUnsafeMutablePointer(to: &vpi) { proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, vsz) }
    if vr == vsz { cwdOK += 1 } else { cwdErr[errno, default: 0] += 1 }

    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var asz = Int(argMax); var abuf = [UInt8](repeating: 0, count: asz)
    errno = 0
    if sysctl(&mib, 3, &abuf, &asz, nil, 0) == 0 { argvOK += 1 } else { argvErr[errno, default: 0] += 1 }

    var pbuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    errno = 0
    if proc_pidpath(pid, &pbuf, UInt32(pbuf.count)) > 0 { pathOK += 1 } else { pathErr[errno, default: 0] += 1 }
}
func describe(_ ok: Int, _ errs: [Int32: Int]) -> String {
    var s = "ok=\(ok)"
    for (e, c) in errs.sorted(by: { $0.key < $1.key }) { s += "  \(String(cString: strerror(e)))=\(c)" }
    return s
}
print("PROC_PIDVNODEPATHINFO  \(describe(cwdOK, cwdErr))")
print("KERN_PROCARGS2         \(describe(argvOK, argvErr))")
print("proc_pidpath           \(describe(pathOK, pathErr))")
