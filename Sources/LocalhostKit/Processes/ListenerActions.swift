import Foundation

/// What can be done with a row, decided without doing any of it.
///
/// Kept separate from the code that performs the action so the decisions —
/// which URL, which folder, whether killing is even allowed — are testable
/// without opening a browser or signalling anything.
public enum ListenerAction: Hashable, Sendable, CaseIterable {
    case openInBrowser
    case copyURL
    /// For a listener that is not a web server, where a URL would be a lie but
    /// the number is still worth having.
    case copyPort
    case openInTerminal
    case revealInFinder
    /// The command that started this, to paste into a shell. See ``StartCommand``
    /// for why the app hands this over instead of restarting the process itself.
    case copyStartCommand
    case terminate

    public var title: String {
        switch self {
        case .openInBrowser: return "Open in Browser"
        case .copyURL: return "Copy URL"
        case .copyPort: return "Copy Port Number"
        case .openInTerminal: return "Open in Terminal"
        case .revealInFinder: return "Reveal in Finder"
        case .copyStartCommand: return "Copy Start Command"
        case .terminate: return "Quit Process…"
        }
    }

    public var symbol: String {
        switch self {
        case .openInBrowser: return "safari"
        case .copyURL: return "doc.on.doc"
        case .copyPort: return "number"
        case .openInTerminal: return "terminal"
        case .revealInFinder: return "folder"
        case .copyStartCommand: return "text.append"
        case .terminate: return "xmark.circle"
        }
    }
}

extension ListenerPresentation {
    /// Whether opening this in a browser could possibly work.
    ///
    /// Offering it everywhere was a promise the row could not keep: clicking
    /// OneDrive on 42050 opens a tab that fails to connect. Two separate
    /// reasons disqualify a row.
    ///
    /// A listener you did not run to serve a site — an application of yours, or
    /// a piece of the operating system — is not a web page, whatever port it
    /// happens to hold.
    ///
    /// And a database is not a web page either, even when it *is* yours: a
    /// Postgres container is a dev server by every other measure, and
    /// `http://localhost:5432` is still a protocol error.
    public var servesHTTP: Bool {
        guard prominence == .devServer else { return false }
        if let runtime, Self.nonHTTPRuntimes.contains(runtime.name) { return false }
        return !Self.nonHTTPPorts.contains(listener.port)
    }

    /// Wire protocols that speak anything but HTTP. Elasticsearch and RabbitMQ's
    /// management port are deliberately absent — those really are browsable.
    private static let nonHTTPRuntimes: Set<String> = [
        "PostgreSQL", "MySQL", "Redis", "MongoDB", "Memcached",
    ]

    private static let nonHTTPPorts: Set<UInt16> = [
        5432, 5433,      // PostgreSQL
        3306, 33060,     // MySQL
        6379,            // Redis
        27017, 27018,    // MongoDB
        11211,           // Memcached
        1433,            // SQL Server
        5672,            // AMQP — 15672 is the management UI and is browsable
        9092,            // Kafka
        2181,            // ZooKeeper
    ]

    /// `localhost` rather than the bound address: a server on `0.0.0.0` is not
    /// reachable at `http://0.0.0.0/`, and `::` is worse.
    public var localURL: URL? {
        URL(string: "http://localhost:\(listener.port)")
    }

    /// The project root if we found one, otherwise wherever the process is
    /// working. Nil for processes we cannot read, which is most of the system.
    public var folderToReveal: URL? {
        if case let .project(_, root, _) = attribution { return root }
        guard let directory = listener.process.workingDirectory, directory != "/" else { return nil }
        return URL(fileURLWithPath: directory)
    }

    /// Only our own processes can be signalled, and the absence of `startedAt`
    /// is what proves a process is not ours.
    public var canTerminate: Bool { listener.process.isOurs }

    public func supports(_ action: ListenerAction) -> Bool {
        switch action {
        case .openInBrowser, .copyURL: return servesHTTP && localURL != nil
        // The port number is useful for anything — it is what you paste into a
        // database client, or into a search here.
        case .copyPort: return !servesHTTP
        case .openInTerminal, .revealInFinder: return folderToReveal != nil
        case .copyStartCommand: return startCommand != nil
        case .terminate: return canTerminate
        }
    }

    public var availableActions: [ListenerAction] {
        ListenerAction.allCases.filter(supports)
    }

    public var startCommand: StartCommand? { StartCommand(for: listener.process) }

    /// Names the process the way a confirmation should: unambiguously.
    public var terminationDescription: String {
        var description = "\(listener.process.name) (pid \(listener.process.pid)) on port \(listener.port)"
        if let label { description = "\(label) — " + description }
        return description
    }
}
