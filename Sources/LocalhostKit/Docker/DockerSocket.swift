import Darwin
import Foundation

/// A single HTTP request over a Unix domain socket.
///
/// Deliberately small and synchronous. Docker labelling must never be the
/// reason this app is slow or broken, so every failure here is a returned
/// `nil` and every wait is bounded.
enum DockerSocket {
    /// Where the three runtimes put their socket.
    static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/var/run/docker.sock",                       // Docker Desktop
            "\(home)/.orbstack/run/docker.sock",          // OrbStack
            "\(home)/.colima/default/docker.sock",        // Colima
        ]
    }

    static func firstAvailablePath() -> String? {
        candidatePaths.first { path in
            var status = stat()
            guard stat(path, &status) == 0 else { return false }
            return (status.st_mode & S_IFMT) == S_IFSOCK
        }
    }

    /// Returns the response body, or nil for any failure at all: no socket, no
    /// daemon, a hang, a non-200, malformed framing.
    static func get(_ path: String, socketPath: String, timeout: TimeInterval = 0.75) -> Data? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var limit = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else { return nil }
        _ = withUnsafeMutableBytes(of: &address.sun_path) { raw in
            socketPath.utf8CString.withUnsafeBytes { source in
                memcpy(raw.baseAddress!, source.baseAddress!, source.count)
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        // `Connection: close` so the read ends at EOF instead of blocking on a
        // kept-alive socket until the timeout.
        let request = "GET \(path) HTTP/1.1\r\nHost: docker\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
        guard request.withCString({ send(descriptor, $0, strlen($0), 0) }) > 0 else { return nil }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let read = recv(descriptor, &buffer, buffer.count, 0)
            if read > 0 {
                response.append(contentsOf: buffer[0..<read])
                // A runaway response is a broken daemon, not data we want.
                if response.count > 8 * 1024 * 1024 { return nil }
            } else {
                break
            }
        }
        return body(of: response)
    }

    /// Splits an HTTP/1.1 response and un-chunks it if needed.
    static func body(of response: Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: separator) else { return nil }
        let head = String(decoding: response[..<range.lowerBound], as: UTF8.self)
        guard let status = head.split(separator: "\r\n").first,
              status.contains(" 200") else { return nil }

        let raw = response[range.upperBound...]
        guard head.lowercased().contains("transfer-encoding: chunked") else { return Data(raw) }

        var remaining = Data(raw)
        var decoded = Data()
        while let lineEnd = remaining.range(of: Data("\r\n".utf8)) {
            let header = String(decoding: remaining[..<lineEnd.lowerBound], as: UTF8.self)
            let size = Int(header.split(separator: ";").first.map(String.init) ?? header, radix: 16)
            guard let size, size > 0 else { break }
            let start = lineEnd.upperBound
            guard let end = remaining.index(start, offsetBy: size, limitedBy: remaining.endIndex)
            else { return nil }
            decoded.append(remaining[start..<end])
            // Step past the chunk's trailing CRLF.
            guard let next = remaining.index(end, offsetBy: 2, limitedBy: remaining.endIndex)
            else { break }
            remaining = Data(remaining[next...])
        }
        return decoded
    }
}
