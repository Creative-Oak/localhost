import Darwin
import Foundation

/// A listener plus the best honest explanation of what it is.
///
/// Attribution is deliberately a closed set with a `nothing` case. When we do
/// not know what a port is, the interface says the process name and stops.
public struct ListenerPresentation: Identifiable, Hashable, Sendable {
    public enum Attribution: Hashable, Sendable {
        /// Resolved from the process's working directory.
        case project(name: String, root: URL, source: ProjectResolver.Source)
        /// A system service the table can explain, including launchd-held sockets.
        case knownDaemon(KnownDaemon)
        /// A container publishing this port. The owning process is a Docker
        /// helper, so without this the row would say "com.docker.backend".
        case container(Container)
        /// We could not read a working directory — almost always because the
        /// process belongs to another user.
        case unavailable
        /// We looked and found no marker. Not a failure, just no project.
        case nothing
    }

    /// Whether a row belongs in the list or behind the disclosure.
    ///
    /// The question this app exists to answer is "what has my port, and which
    /// project is it?". A daemon on a random high port is never the answer, and
    /// on a normal machine there are more of those than there are real ones.
    public enum Prominence: Hashable, Sendable {
        /// Something you started: a resolved project, a container, or one of
        /// your own processes running a server we recognise.
        case yours
        /// Everything else — daemons, launchd-held sockets, other users'
        /// processes, and services on ports nobody chose. Folded away, never
        /// hidden, because "nothing is on 5000" would be a lie.
        case system
    }

    public let listener: Listener
    public let attribution: Attribution
    /// What the process is running, from argv. Nil when we cannot tell.
    public let runtime: Runtime?
    /// The branch checked out at the project root, when there is one.
    public let branch: String?

    public init(
        listener: Listener,
        attribution: Attribution,
        runtime: Runtime? = nil,
        branch: String? = nil
    ) {
        self.listener = listener
        self.attribution = attribution
        self.runtime = runtime
        self.branch = branch
    }

    public var id: Listener.ID { listener.id }

    /// Ports at or below this are ones a person picks: 80, 443, 3000, 5432,
    /// 8080, 9000. Above it, almost everything is a service that asked the
    /// operating system for whatever was free.
    static let highestChosenPort: UInt16 = 10_000

    public var prominence: Prominence {
        switch attribution {
        // A resolved project or a published container is the whole point of
        // the app, whatever the port.
        case .project, .container:
            return .yours

        // AirPlay, Screen Sharing and Kerberos are worth explaining when
        // someone goes looking for the port, and worth nothing the rest of the
        // time. The daemon table makes them findable; it does not make them
        // interesting.
        case .knownDaemon:
            return .system

        // Another user's process is never something you started.
        case .unavailable:
            return .system

        case .nothing:
            // No project, so the question is whether this looks like a server
            // you ran. A recognised runtime on a port a person would choose is
            // the evidence; a menu bar app that happens to listen is not.
            guard listener.process.isOurs,
                  runtime != nil,
                  listener.port <= Self.highestChosenPort
            else { return .system }
            return .yours
        }
    }

    /// The label shown in the third column, or `nil` for none.
    public var label: String? {
        switch attribution {
        case let .project(name, _, _): return name
        case let .knownDaemon(daemon): return daemon.label
        case let .container(container): return container.label
        case .unavailable, .nothing: return nil
        }
    }

    public var advice: String? {
        if case let .knownDaemon(daemon) = attribution { return daemon.advice }
        return nil
    }

    /// Ascending port order is predictable and puts the least interesting row
    /// first — on a normal machine that is a Kerberos daemon. Rows are ranked
    /// by how likely they are to be what someone opened the menu to find.
    var rank: Int {
        switch attribution {
        case .project: return 0
        case .container: return 1
        case .nothing, .unavailable: return prominence == .yours ? 2 : 4
        case .knownDaemon: return 3
        }
    }
}

/// Turns scanned listeners into rows. Pure, and separate from both the scan and
/// the interface so it can be tested without either.
public struct ListenerAttributor: Sendable {
    private let resolver: ProjectResolver
    private let containers: ContainerLabels

    public init(
        resolver: ProjectResolver = ProjectResolver(),
        containers: ContainerLabels = ContainerLabels()
    ) {
        self.resolver = resolver
        self.containers = containers
    }

    public func present(_ listeners: [Listener]) -> [ListenerPresentation] {
        // See ListenerScanner.scan: project resolution and branch reading are
        // heavy in autoreleased Foundation objects, and this runs off the main
        // thread every two seconds for as long as the menu is open.
        autoreleasepool { presenting(listeners) }
    }

    private func presenting(_ listeners: [Listener]) -> [ListenerPresentation] {
        // One request per scan, hard-bounded, and an empty map on any failure.
        let published = containers.byPublishedPort()
        return listeners
            .map { listener in
                let attribution = attribution(for: listener, published: published)
                var branch: String?
                if case let .project(_, root, _) = attribution {
                    branch = GitBranch.branch(at: root)
                }
                return ListenerPresentation(
                    listener: listener,
                    attribution: attribution,
                    runtime: RuntimeIdentifier.runtime(
                        arguments: listener.process.arguments,
                        executablePath: listener.process.executablePath),
                    branch: branch)
            }
            .sorted { left, right in
                (left.rank, left.listener.port) < (right.rank, right.listener.port)
            }
    }

    private func attribution(
        for listener: Listener,
        published: [UInt16: Container]
    ) -> ListenerPresentation.Attribution {
        // The daemon table comes first on purpose. For a launchd-held socket the
        // owning process really is launchd and its working directory really is
        // "/", so project resolution would correctly find nothing and the row
        // would read "launchd" with no explanation.
        if let daemon = KnownDaemons.daemon(port: listener.port, processName: listener.process.name) {
            return .knownDaemon(daemon)
        }
        // Checked before the project, because the process holding a published
        // port is a Docker helper whose working directory tells us nothing.
        if let container = published[listener.port] {
            return .container(container)
        }
        guard let directory = listener.process.workingDirectory else {
            return listener.process.isOurs ? .nothing : .unavailable
        }
        guard let project = resolver.project(for: directory) else { return .nothing }
        return .project(name: project.name, root: project.root, source: project.source)
    }
}
