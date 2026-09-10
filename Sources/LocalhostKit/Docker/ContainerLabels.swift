import Foundation

/// A running container, as far as this app is concerned.
public struct Container: Hashable, Sendable {
    public let name: String
    public let image: String
    /// `com.docker.compose.project`, when the container was started by Compose.
    public let composeProject: String?
    public let composeService: String?
    /// Host ports the container publishes.
    public let publishedPorts: Set<UInt16>

    /// What the row should say. A Compose service reads better as
    /// "myapp · web" than as the generated container name "myapp-web-1".
    public var label: String {
        guard let composeProject, let composeService else { return name }
        return "\(composeProject) · \(composeService)"
    }
}

/// Reads container names from Docker's socket, and never does anything else.
///
/// Two rules keep this from becoming container management:
///
/// 1. **We label, we never act.** There is no start, stop, restart, exec or
///    logs here, and there is no code path that could grow one — the only
///    request this type can make is a GET of the container list.
/// 2. **It degrades to nothing.** No socket, no daemon, a hang, a malformed
///    reply: every one of those produces an empty map, and rows render without
///    container names. This feature can never be the reason the app fails.
public struct ContainerLabels: Sendable {
    private let socketPath: String?
    private let fetch: @Sendable (String) -> Data?

    public init() {
        self.socketPath = DockerSocket.firstAvailablePath()
        self.fetch = { path in
            DockerSocket.get("/containers/json", socketPath: path)
        }
    }

    /// For tests: decode a captured or constructed response without a daemon.
    init(socketPath: String?, fetch: @escaping @Sendable (String) -> Data?) {
        self.socketPath = socketPath
        self.fetch = fetch
    }

    public var isAvailable: Bool { socketPath != nil }

    public func containers() -> [Container] {
        guard let socketPath, let data = fetch(socketPath) else { return [] }
        return Self.decode(data)
    }

    /// Host port to container. Ports published by more than one container are
    /// impossible, so the first wins and the situation cannot arise.
    public func byPublishedPort() -> [UInt16: Container] {
        var map: [UInt16: Container] = [:]
        for container in containers() {
            for port in container.publishedPorts where map[port] == nil {
                map[port] = container
            }
        }
        return map
    }

    // MARK: - Decoding

    /// Docker's wire shape, which is capitalised and includes `Type` — a name
    /// Swift will not accept as a member.
    private struct Payload: Decodable {
        let names: [String]?
        let image: String?
        let labels: [String: String]?
        let ports: [Port]?

        enum CodingKeys: String, CodingKey {
            case names = "Names"
            case image = "Image"
            case labels = "Labels"
            case ports = "Ports"
        }

        struct Port: Decodable {
            let publicPort: Int?
            let networkProtocol: String?

            enum CodingKeys: String, CodingKey {
                case publicPort = "PublicPort"
                case networkProtocol = "Type"
            }
        }
    }

    static func decode(_ data: Data) -> [Container] {
        guard let payloads = try? JSONDecoder().decode([Payload].self, from: data) else { return [] }
        return payloads.compactMap { payload in
            // Docker prefixes container names with a slash.
            let name = (payload.names?.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !name.isEmpty else { return nil }

            let published = Set((payload.ports ?? []).compactMap { port -> UInt16? in
                // Only published TCP ports can correspond to a listener we see.
                guard port.networkProtocol ?? "tcp" == "tcp",
                      let hostPort = port.publicPort,
                      hostPort > 0, hostPort <= Int(UInt16.max)
                else { return nil }
                return UInt16(hostPort)
            })

            return Container(
                name: name,
                image: payload.image ?? "",
                composeProject: payload.labels?["com.docker.compose.project"],
                composeService: payload.labels?["com.docker.compose.service"],
                publishedPorts: published)
        }
    }
}
