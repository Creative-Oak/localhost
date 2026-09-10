import Foundation
import Testing
@testable import LocalhostKit

/// Decoding is tested against each runtime's shape, and every failure mode is
/// tested for producing nothing rather than an error.
@Suite("Docker container labels")
struct ContainerLabelsTests {
    private func labels(returning json: String?) -> ContainerLabels {
        ContainerLabels(socketPath: "/tmp/fake.sock") { _ in json?.data(using: .utf8) }
    }

    // Docker Desktop publishes on 0.0.0.0 and duplicates the entry for IPv6.
    private let dockerDesktop = """
    [{"Id":"a1","Names":["/web"],"Image":"nginx:alpine",
      "Labels":{},
      "Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},
               {"IP":"::","PrivatePort":80,"PublicPort":8080,"Type":"tcp"}]}]
    """

    // OrbStack reports the same API, with Compose labels present.
    private let orbStack = """
    [{"Id":"b2","Names":["/shop-api-1"],"Image":"shop/api:latest",
      "Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"api"},
      "Ports":[{"IP":"0.0.0.0","PrivatePort":3000,"PublicPort":4000,"Type":"tcp"}]},
     {"Id":"c3","Names":["/shop-db-1"],"Image":"postgres:16",
      "Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"db"},
      "Ports":[{"IP":"0.0.0.0","PrivatePort":5432,"PublicPort":5432,"Type":"tcp"}]}]
    """

    // Colima, including an unpublished port and a UDP mapping.
    private let colima = """
    [{"Id":"d4","Names":["/cache"],"Image":"redis:7",
      "Labels":{},
      "Ports":[{"PrivatePort":6379,"Type":"tcp"},
               {"IP":"0.0.0.0","PrivatePort":6379,"PublicPort":6379,"Type":"tcp"},
               {"IP":"0.0.0.0","PrivatePort":9999,"PublicPort":9999,"Type":"udp"}]}]
    """

    @Test("decodes Docker Desktop, collapsing the duplicated IPv6 entry")
    func decodesDockerDesktop() throws {
        let container = try #require(labels(returning: dockerDesktop).containers().first)
        #expect(container.name == "web")
        #expect(container.image == "nginx:alpine")
        #expect(container.publishedPorts == [8080])
        #expect(container.label == "web", "no compose labels, so the container name stands")
    }

    @Test("decodes OrbStack and prefers the compose service name")
    func decodesOrbStack() throws {
        let map = labels(returning: orbStack).byPublishedPort()
        #expect(map[4000]?.label == "shop · api")
        #expect(map[5432]?.label == "shop · db")
        #expect(map[5432]?.image == "postgres:16")
    }

    @Test("decodes Colima, ignoring unpublished and non-TCP ports")
    func decodesColima() throws {
        let container = try #require(labels(returning: colima).containers().first)
        // A port with no PublicPort is not reachable from the host, and a UDP
        // mapping can never match a TCP listener.
        #expect(container.publishedPorts == [6379])
    }

    @Test("degrades to nothing", arguments: [
        nil,                            // no daemon, or a hang
        "",                             // empty reply
        "not json at all",
        "{\"error\":\"permission denied\"}",
        "[]",                           // running, no containers
        "[{\"Id\":\"x\",\"Names\":[]}]",  // a container with no usable name
    ])
    func degradesToNothing(json: String?) {
        // Every one of these must produce an empty map, never a thrown error.
        #expect(labels(returning: json).byPublishedPort().isEmpty)
    }

    @Test("is unavailable when there is no socket")
    func noSocketMeansUnavailable() {
        let none = ContainerLabels(socketPath: nil) { _ in Data("[]".utf8) }
        #expect(!none.isAvailable)
        #expect(none.containers().isEmpty)
    }

    @Test("a container port outranks project resolution")
    func containerLabelWinsForPublishedPort() {
        let listener = Listener(
            port: 4000,
            addresses: ["0.0.0.0"],
            families: [.ipv4],
            process: ProcessIdentity(
                pid: 5, startedAt: 1, uid: getuid(),
                name: "com.docker.backend", workingDirectory: "/"))

        let rows = ListenerAttributor(containers: labels(returning: orbStack)).present([listener])
        #expect(rows.first?.label == "shop · api")
        #expect(rows.first?.prominence == .yours)
    }
}

@Suite("Docker HTTP framing")
struct DockerSocketTests {
    @Test("reads a Content-Length response")
    func plainBody() throws {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]".utf8)
        #expect(DockerSocket.body(of: response) == Data("[]".utf8))
    }

    @Test("un-chunks a chunked response")
    func chunkedBody() throws {
        let response = Data(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n[{\"a\r\n3\r\n\":1\r\n2\r\n}]\r\n0\r\n\r\n".utf8)
        let body = try #require(DockerSocket.body(of: response))
        #expect(String(decoding: body, as: UTF8.self) == "[{\"a\":1}]")
    }

    @Test("refuses a non-200")
    func rejectsErrorStatus() {
        let response = Data("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 2\r\n\r\n{}".utf8)
        #expect(DockerSocket.body(of: response) == nil)
    }

    @Test("refuses a response with no header break")
    func rejectsTruncatedResponse() {
        #expect(DockerSocket.body(of: Data("HTTP/1.1 200 OK".utf8)) == nil)
    }
}

/// The rule that Docker can never be the reason the app fails, tested against
/// real sockets rather than injected stubs.
@Suite("Docker socket resilience", .serialized)
struct DockerSocketResilienceTests {
    private func temporaryPath() -> String {
        NSTemporaryDirectory() + "localhost-docker-\(UUID().uuidString).sock"
    }

    @Test("a missing socket returns nothing immediately")
    func missingSocket() {
        let started = ContinuousClock.now
        #expect(DockerSocket.get("/containers/json", socketPath: temporaryPath()) == nil)
        #expect(ContinuousClock.now - started < .milliseconds(100))
    }

    @Test("a socket file with nothing listening returns nothing immediately")
    func deadSocketFile() throws {
        let path = temporaryPath()
        // Bind without listening, then close: the file remains, connect refuses.
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { memcpy(raw.baseAddress!, $0.baseAddress!, $0.count) }
        }
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(descriptor)
        defer { unlink(path) }

        let started = ContinuousClock.now
        #expect(DockerSocket.get("/containers/json", socketPath: path) == nil)
        #expect(ContinuousClock.now - started < .milliseconds(200))
    }

    @Test("a daemon that accepts and never answers gives up quickly")
    func hungDaemon() throws {
        let path = temporaryPath()
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { memcpy(raw.baseAddress!, $0.baseAddress!, $0.count) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(listen(descriptor, 4) == 0)
        defer { close(descriptor); unlink(path) }

        // Never accepted, never answered — the connection completes from the
        // backlog and then hangs, which is the worst realistic case.
        let started = ContinuousClock.now
        #expect(DockerSocket.get("/containers/json", socketPath: path, timeout: 0.3) == nil)
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(1), "gave up after \(elapsed)")
    }
}
