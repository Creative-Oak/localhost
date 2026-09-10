import Darwin
import Foundation

/// A real listening socket on a real ephemeral port.
///
/// The scanner tests do not mock anything: they open one of these, ask the
/// scanner what is listening, and expect to be told about it.
final class TestListener {
    let descriptor: Int32
    let port: UInt16

    enum Failure: Error { case socket, bind, listen, name }

    init(loopbackOnly: Bool = true) throws {
        // Work through a local, not `self.descriptor`: the closures below
        // would otherwise capture a partly initialised `self`.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                       // let the kernel choose
        address.sin_addr = in_addr(s_addr: loopbackOnly ? INADDR_LOOPBACK.bigEndian : INADDR_ANY)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw Failure.bind }
        guard listen(fd, 1) == 0 else { close(fd); throw Failure.listen }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { close(fd); throw Failure.name }
        descriptor = fd
        port = UInt16(bigEndian: actual.sin_port)
    }

    deinit { close(descriptor) }
}
