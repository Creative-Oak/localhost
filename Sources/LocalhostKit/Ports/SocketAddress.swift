import Darwin
import Foundation

/// Presentable forms of the two address families, shared by both scanners.
enum SocketAddress {
    static func string(_ address: in_addr) -> String {
        var address = address
        return render(family: AF_INET, source: &address, capacity: Int(INET_ADDRSTRLEN))
    }

    static func string(_ address: in6_addr) -> String {
        var address = address
        return render(family: AF_INET6, source: &address, capacity: Int(INET6_ADDRSTRLEN))
    }

    private static func render(family: Int32, source: UnsafeRawPointer, capacity: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: capacity)
        let ok = buffer.withUnsafeMutableBufferPointer { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return base.withMemoryRebound(to: CChar.self, capacity: raw.count) { text in
                inet_ntop(family, source, text, socklen_t(raw.count)) != nil
            }
        }
        guard ok else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
