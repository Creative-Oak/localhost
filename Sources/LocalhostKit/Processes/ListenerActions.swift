import Foundation

/// What can be done with a row, decided without doing any of it.
///
/// Kept separate from the code that performs the action so the decisions —
/// which URL, which folder, whether killing is even allowed — are testable
/// without opening a browser or signalling anything.
public enum ListenerAction: Hashable, Sendable, CaseIterable {
    case openInBrowser
    case copyURL
    case revealInFinder
    case terminate

    public var title: String {
        switch self {
        case .openInBrowser: return "Open in Browser"
        case .copyURL: return "Copy URL"
        case .revealInFinder: return "Reveal in Finder"
        case .terminate: return "Quit Process…"
        }
    }

    public var symbol: String {
        switch self {
        case .openInBrowser: return "safari"
        case .copyURL: return "doc.on.doc"
        case .revealInFinder: return "folder"
        case .terminate: return "xmark.circle"
        }
    }
}

extension ListenerPresentation {
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
        case .openInBrowser, .copyURL: return localURL != nil
        case .revealInFinder: return folderToReveal != nil
        case .terminate: return canTerminate
        }
    }

    public var availableActions: [ListenerAction] {
        ListenerAction.allCases.filter(supports)
    }

    /// Names the process the way a confirmation should: unambiguously.
    public var terminationDescription: String {
        var description = "\(listener.process.name) (pid \(listener.process.pid)) on port \(listener.port)"
        if let label { description = "\(label) — " + description }
        return description
    }
}
