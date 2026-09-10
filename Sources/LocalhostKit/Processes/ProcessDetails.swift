import Darwin
import Foundation

/// Reads what a process will tell us about itself.
///
/// Everything here degrades rather than fails. For the current user's
/// processes all four facts are available; for anyone else's, only the
/// executable path is, which is still enough to put a name on the row.
public struct ProcessDetails: Sendable {
    public init() {}

    public func identity(of pid: pid_t, fallbackUID: uid_t) -> ProcessIdentity {
        let executablePath = Self.executablePath(of: pid)

        // PROC_PIDTBSDINFO is EPERM for other users, which is also how we learn
        // that this process is not ours to signal.
        guard let info = Self.bsdInfo(of: pid) else {
            return ProcessIdentity(
                pid: pid,
                startedAt: nil,
                uid: fallbackUID,
                name: executablePath.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)",
                executablePath: executablePath)
        }

        let name = Self.string(info.pbi_name).isEmpty
            ? Self.string(info.pbi_comm)
            : Self.string(info.pbi_name)

        return ProcessIdentity(
            pid: pid,
            startedAt: time_t(info.pbi_start_tvsec),
            uid: info.pbi_uid,
            name: name.isEmpty ? "pid \(pid)" : name,
            executablePath: executablePath,
            arguments: Self.arguments(of: pid),
            workingDirectory: Self.workingDirectory(of: pid))
    }

    // MARK: - Facts

    public static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        return read == size ? info : nil
    }

    /// Available for every same-user process, and the basis of the project column.
    public static func workingDirectory(of pid: pid_t) -> String? {
        var paths = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let read = withUnsafeMutablePointer(to: &paths) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
        }
        guard read == size else { return nil }
        let path = string(paths.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// Succeeds even for processes that deny everything else, so root-owned
    /// listeners can still be named.
    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let written = buffer.withUnsafeMutableBufferPointer { raw -> Int32 in
            guard let base = raw.baseAddress else { return 0 }
            return base.withMemoryRebound(to: CChar.self, capacity: raw.count) {
                proc_pidpath(pid, $0, UInt32(raw.count))
            }
        }
        guard written > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    public static func arguments(of pid: pid_t) -> [String]? {
        commandLine(of: pid)?.arguments
    }

    /// Everything `KERN_PROCARGS2` carries: argv *and* the environment.
    ///
    /// The environment matters for relaunching. A dev server started with
    /// `PORT=4000 NODE_ENV=development npm run dev` and restarted without those
    /// is a different process wearing the same name.
    ///
    /// Layout: `argc`, the exec path, null padding, `argc` arguments, then
    /// environment entries until they run out.
    public static func commandLine(of pid: pid_t) -> (arguments: [String], environment: [String: String])? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argumentMaximum
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }

        let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var cursor = MemoryLayout<Int32>.size

        func next() -> String? {
            guard cursor < size else { return nil }
            let start = cursor
            while cursor < size, buffer[cursor] != 0 { cursor += 1 }
            let value = String(decoding: buffer[start..<cursor], as: UTF8.self)
            while cursor < size, buffer[cursor] == 0 { cursor += 1 }  // exec path is null-padded
            return value
        }

        _ = next()                                   // exec path, already have it
        var arguments: [String] = []
        for _ in 0..<Int(max(0, count)) {
            guard let argument = next() else { break }
            arguments.append(argument)
        }
        guard !arguments.isEmpty else { return nil }

        var environment: [String: String] = [:]
        while let entry = next(), !entry.isEmpty {
            // Only split on the first `=`; values contain them routinely.
            guard let separator = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return (arguments, environment)
    }

    private static let argumentMaximum: Int = {
        var mib = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 256 * 1024 }
        return Int(value)
    }()

    // MARK: - Fixed-size C char arrays

    /// Must stay generic over `T`. Taking these tuples as `Any` boxes anything
    /// larger than three words, so `withUnsafeBytes` reads the existential box
    /// instead of the characters — and returns an empty string rather than an
    /// error. That mistake cost the spike an afternoon and looked exactly like
    /// "macOS no longer exposes working directories".
    static func string<T>(_ characters: T) -> String {
        var characters = characters
        return withUnsafeBytes(of: &characters) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
