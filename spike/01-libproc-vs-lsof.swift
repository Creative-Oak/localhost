import Darwin
import Foundation

// ─── helpers ─────────────────────────────────────────────────────────────────

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func cString<T>(_ tuple: T, capacity: Int) -> String? {
    var t = tuple
    return withUnsafeBytes(of: &t) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

struct Probe {
    var ok = 0
    var eperm = 0
    var esrch = 0
    var empty = 0            // call succeeded but value was blank
    var otherErr: [Int32: Int] = [:]
    mutating func record(_ result: Bool, blank: Bool = false, err: Int32 = 0) {
        if result { blank ? (empty += 1) : (ok += 1) }
        else if err == EPERM { eperm += 1 }
        else if err == ESRCH { esrch += 1 }
        else { otherErr[err, default: 0] += 1 }
    }
    var line: String {
        var s = "ok=\(ok) blank=\(empty) EPERM=\(eperm) ESRCH=\(esrch)"
        for (e, c) in otherErr.sorted(by: { $0.key < $1.key }) {
            s += " errno\(e)(\(String(cString: strerror(e))))=\(c)"
        }
        return s
    }
}

// ─── pid enumeration ─────────────────────────────────────────────────────────

func allPIDs() -> [pid_t] {
    let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard bytes > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 32)
    let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard got > 0 else { return [] }
    return pids.prefix(Int(got) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
}

// ─── per-process facts ───────────────────────────────────────────────────────

struct BSDInfo { let uid: uid_t; let name: String; let startedAt: UInt64 }

func bsdInfo(_ pid: pid_t) -> (BSDInfo?, Int32) {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let r = withUnsafeMutablePointer(to: &info) {
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
    }
    guard r == size else { return (nil, errno) }
    let name = cString(info.pbi_name, capacity: 32) ?? ""
    let comm = cString(info.pbi_comm, capacity: 16) ?? ""
    return (BSDInfo(uid: info.pbi_uid,
                    name: name.isEmpty ? comm : name,
                    startedAt: UInt64(info.pbi_start_tvsec)), 0)
}

func workingDirectory(_ pid: pid_t) -> (String?, Int32) {
    var vpi = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    let r = withUnsafeMutablePointer(to: &vpi) {
        proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
    }
    guard r == size else { return (nil, errno) }
    let path = cString(vpi.pvi_cdir.vip_path, capacity: Int(MAXPATHLEN)) ?? ""
    return (path, 0)
}

func executablePath(_ pid: pid_t) -> (String?, Int32) {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
    let r = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard r > 0 else { return (nil, errno) }
    return (String(cString: buf), 0)
}

var argMax: Int = {
    var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctl(&mib, 2, &value, &size, nil, 0) == 0 else { return 256 * 1024 }
    return Int(value)
}()

func arguments(_ pid: pid_t) -> ([String]?, Int32) {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = argMax
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return (nil, errno) }
    guard size > MemoryLayout<Int32>.size else { return (nil, 0) }
    let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    var cursor = MemoryLayout<Int32>.size
    func nextCString() -> String? {
        guard cursor < size else { return nil }
        let start = cursor
        while cursor < size && buf[cursor] != 0 { cursor += 1 }
        let s = String(decoding: buf[start..<cursor], as: UTF8.self)
        while cursor < size && buf[cursor] == 0 { cursor += 1 }   // skip padding nulls
        return s
    }
    _ = nextCString()                                  // exec path
    var args: [String] = []
    for _ in 0..<Int(max(0, argc)) {
        guard let a = nextCString() else { break }
        args.append(a)
    }
    return (args, 0)
}

// ─── libproc listener scan ───────────────────────────────────────────────────

struct Row: Hashable {
    let pid: pid_t; let port: UInt16; let address: String; let family: String
}

func formatIPv4(_ addr: in_addr) -> String {
    var a = addr
    var out = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &a, &out, socklen_t(INET_ADDRSTRLEN))
    return String(cString: out)
}
func formatIPv6(_ addr: in6_addr) -> String {
    var a = addr
    var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    inet_ntop(AF_INET6, &a, &out, socklen_t(INET6_ADDRSTRLEN))
    return String(cString: out)
}

var fdListProbe = Probe()

func scanLibproc(recordProbes: Bool) -> [Row] {
    var rows: [Row] = []
    let sockSize = Int32(MemoryLayout<socket_fdinfo>.size)
    for pid in allPIDs() {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if bytes <= 0 {
            if recordProbes { fdListProbe.record(false, err: errno) }
            continue
        }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 16)
        let got = fds.withUnsafeMutableBufferPointer { b in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, b.baseAddress, Int32(b.count * MemoryLayout<proc_fdinfo>.size))
        }
        if got <= 0 {
            if recordProbes { fdListProbe.record(false, err: errno) }
            continue
        }
        if recordProbes { fdListProbe.record(true) }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) {
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            var si = socket_fdinfo()
            let r = withUnsafeMutablePointer(to: &si) {
                proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, $0, sockSize)
            }
            guard r == sockSize, si.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = tcp.tcpsi_ini
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
            let isV4 = (ini.insi_vflag & UInt8(INI_IPV4)) != 0
            let addr = isV4 ? formatIPv4(ini.insi_laddr.ina_46.i46a_addr4)
                            : formatIPv6(ini.insi_laddr.ina_6)
            rows.append(Row(pid: pid, port: port, address: addr, family: isV4 ? "IPv4" : "IPv6"))
        }
    }
    return rows
}

// ─── lsof scan ───────────────────────────────────────────────────────────────

func scanLsof() -> [Row] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    p.arguments = ["-i", "-P", "-n", "-sTCP:LISTEN", "-F", "pPn"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    var rows: [Row] = []
    var pid: pid_t = 0
    var isTCP = false
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        switch line.first {
        case "p": pid = pid_t(line.dropFirst()) ?? 0
        case "P": isTCP = line.dropFirst() == "TCP"
        case "n":
            guard isTCP else { continue }
            let name = line.dropFirst()
            guard let colon = name.lastIndex(of: ":") else { continue }
            guard let port = UInt16(name[name.index(after: colon)...]) else { continue }
            var addr = String(name[..<colon])
            let v6 = addr.hasPrefix("[")
            if v6 { addr = String(addr.dropFirst().dropLast()) }
            rows.append(Row(pid: pid, port: port, address: addr, family: v6 || addr.contains(":") ? "IPv6" : "IPv4"))
        default: break
        }
    }
    return rows
}

// ─── run ─────────────────────────────────────────────────────────────────────

let me = getuid()
print("=== spike: libproc vs lsof, cwd + argv availability ===")
print("uid=\(me)  pids visible=\(allPIDs().count)\n")

// Q1 — timings
func bench(_ label: String, _ runs: Int, _ body: () -> [Row]) -> [Row] {
    var times: [Double] = []
    var last: [Row] = []
    for _ in 0..<runs {
        let t = now(); last = body(); times.append(now() - t)
    }
    times.sort()
    let ms = { (d: Double) in String(format: "%.1f", d * 1000) }
    print("\(label.padding(toLength: 10, withPad: " ", startingAt: 0)) min=\(ms(times[0]))ms  median=\(ms(times[times.count/2]))ms  max=\(ms(times.last!))ms   rows=\(last.count)")
    return last
}

_ = scanLibproc(recordProbes: false)   // warm
let libRows = bench("libproc", 7) { scanLibproc(recordProbes: false) }
let lsofRows = bench("lsof", 5) { scanLsof() }
_ = scanLibproc(recordProbes: true)

print("\n--- Q1 coverage: what libproc sees vs lsof ---")
let libSet = Set(libRows.map { "\($0.pid):\($0.port)" })
let lsofSet = Set(lsofRows.map { "\($0.pid):\($0.port)" })
print("libproc unique (pid,port): \(libSet.count)   lsof unique: \(lsofSet.count)")
let onlyLsof = lsofSet.subtracting(libSet).sorted()
let onlyLib  = libSet.subtracting(lsofSet).sorted()
print("only lsof sees (\(onlyLsof.count)): \(onlyLsof.prefix(20).joined(separator: " "))")
print("only libproc sees (\(onlyLib.count)): \(onlyLib.prefix(20).joined(separator: " "))")
print("PROC_PIDLISTFDS across all pids: \(fdListProbe.line)")

// Q2/Q3/Q4 — availability by ownership
print("\n--- Q2/Q3/Q4: per-process facts, bucketed by owner ---")
var mineCwd = Probe(), otherCwd = Probe()
var mineArgs = Probe(), otherArgs = Probe()
var minePath = Probe(), otherPath = Probe()
var mineBSD = Probe(), otherBSD = Probe()
var mineCount = 0, otherCount = 0, unknownOwner = 0

for pid in allPIDs() {
    let (info, bsdErr) = bsdInfo(pid)
    guard let info else {
        unknownOwner += 1
        mineBSD.record(false, err: bsdErr); continue
    }
    let mine = info.uid == me
    if mine { mineCount += 1; mineBSD.record(true) } else { otherCount += 1; otherBSD.record(true) }

    let (cwd, cwdErr) = workingDirectory(pid)
    let (args, argsErr) = arguments(pid)
    let (path, pathErr) = executablePath(pid)
    if mine {
        mineCwd.record(cwd != nil, blank: cwd?.isEmpty ?? false, err: cwdErr)
        mineArgs.record(args != nil, blank: args?.isEmpty ?? false, err: argsErr)
        minePath.record(path != nil, blank: path?.isEmpty ?? false, err: pathErr)
    } else {
        otherCwd.record(cwd != nil, blank: cwd?.isEmpty ?? false, err: cwdErr)
        otherArgs.record(args != nil, blank: args?.isEmpty ?? false, err: argsErr)
        otherPath.record(path != nil, blank: path?.isEmpty ?? false, err: pathErr)
    }
}
print("processes: mine=\(mineCount) other-user=\(otherCount) bsdinfo-denied=\(unknownOwner)")
print("PROC_PIDTBSDINFO      mine: \(mineBSD.line)")
print("                     other: \(otherBSD.line)")
print("PROC_PIDVNODEPATHINFO mine: \(mineCwd.line)")
print("                     other: \(otherCwd.line)")
print("KERN_PROCARGS2        mine: \(mineArgs.line)")
print("                     other: \(otherArgs.line)")
print("proc_pidpath          mine: \(minePath.line)")
print("                     other: \(otherPath.line)")

// The listeners themselves, in detail
print("\n--- listeners, with attribution ---")
var seen = Set<String>()
for row in libRows.sorted(by: { ($0.port, $0.pid) < ($1.port, $1.pid) }) {
    let key = "\(row.pid):\(row.port)"
    if !seen.insert(key).inserted { continue }
    let (info, _) = bsdInfo(row.pid)
    let (cwd, cwdErr) = workingDirectory(row.pid)
    let (args, _) = arguments(row.pid)
    let owner = info.map { $0.uid == me ? "me" : "uid \($0.uid)" } ?? "?"
    let name = info?.name ?? "?"
    let cwdText = cwd.map { $0.isEmpty ? "<blank>" : $0 } ?? "DENIED(\(String(cString: strerror(cwdErr))))"
    let argText = args.map { $0.prefix(4).joined(separator: " ") } ?? "DENIED"
    print(String(format: "%6d  %-22s pid %-7d %-8s", Int(row.port), (name as NSString).utf8String!, Int(row.pid), (owner as NSString).utf8String!))
    print("        cwd: \(cwdText)")
    print("        argv: \(argText.isEmpty ? "<none>" : argText)")
}
