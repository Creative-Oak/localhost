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
        /// We could not read a working directory — almost always because the
        /// process belongs to another user.
        case unavailable
        /// We looked and found no marker. Not a failure, just no project.
        case nothing
    }

    public let listener: Listener
    public let attribution: Attribution

    public var id: Listener.ID { listener.id }

    /// The label shown in the third column, or `nil` for none.
    public var label: String? {
        switch attribution {
        case let .project(name, _, _): return name
        case let .knownDaemon(daemon): return daemon.label
        case .unavailable, .nothing: return nil
        }
    }

    public var advice: String? {
        if case let .knownDaemon(daemon) = attribution { return daemon.advice }
        return nil
    }
}

/// Turns scanned listeners into rows. Pure, and separate from both the scan and
/// the interface so it can be tested without either.
public struct ListenerAttributor: Sendable {
    private let resolver: ProjectResolver

    public init(resolver: ProjectResolver = ProjectResolver()) {
        self.resolver = resolver
    }

    public func present(_ listeners: [Listener]) -> [ListenerPresentation] {
        listeners.map { listener in
            ListenerPresentation(listener: listener, attribution: attribution(for: listener))
        }
    }

    private func attribution(for listener: Listener) -> ListenerPresentation.Attribution {
        // The daemon table comes first on purpose. For a launchd-held socket the
        // owning process really is launchd and its working directory really is
        // "/", so project resolution would correctly find nothing and the row
        // would read "launchd" with no explanation.
        if let daemon = KnownDaemons.daemon(port: listener.port, processName: listener.process.name) {
            return .knownDaemon(daemon)
        }
        guard let directory = listener.process.workingDirectory else {
            return listener.process.isOurs ? .nothing : .unavailable
        }
        guard let project = resolver.project(for: directory) else { return .nothing }
        return .project(name: project.name, root: project.root, source: project.source)
    }
}
