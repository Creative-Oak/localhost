import Foundation

/// Rows grouped by the project they belong to.
///
/// This is the "project stack" idea arrived at from the other end. Rather than
/// asking someone to declare that their frontend, API and database belong
/// together, the grouping falls out of attribution: they already resolve to the
/// same project root, and Compose already names its own project. Nothing is
/// configured, so nothing can be configured wrongly.
public struct ListenerSection: Identifiable, Hashable, Sendable {
    /// Nil for a row that belongs to no group, which is rendered on its own.
    public let project: String?
    public let rows: [ListenerPresentation]

    public var id: String { project ?? "ungrouped-\(rows.first?.id.port ?? 0)-\(rows.first?.id.pid ?? 0)" }

    /// Only the rows in this group that we are actually allowed to signal.
    public var terminableRows: [ListenerPresentation] {
        rows.filter(\.canTerminate)
    }

    /// A branch belongs to the project, not to each of its processes.
    public var branch: String? {
        rows.compactMap(\.branch).first
    }
}

extension ListenerPresentation {
    /// What ties rows into a stack. A Compose project and a checked-out
    /// repository with the same name are the same thing to a developer.
    public var groupingKey: String? {
        switch attribution {
        case let .project(name, _, _):
            return name
        case let .container(container):
            return container.composeProject
        case .knownDaemon, .unavailable, .nothing:
            return nil
        }
    }
}

public enum ListenerGrouping {
    /// Preserves the incoming order, which is already ranked by relevance.
    ///
    /// A group of one is not a group — it would add a heading and an indent to
    /// say nothing — so single rows stay ungrouped.
    public static func sections(from rows: [ListenerPresentation]) -> [ListenerSection] {
        var counts: [String: Int] = [:]
        for row in rows {
            guard let key = row.groupingKey else { continue }
            counts[key, default: 0] += 1
        }

        var sections: [ListenerSection] = []
        var indexOfSection: [String: Int] = [:]

        for row in rows {
            guard let key = row.groupingKey, counts[key, default: 0] > 1 else {
                sections.append(ListenerSection(project: nil, rows: [row]))
                continue
            }
            if let existing = indexOfSection[key] {
                sections[existing] = ListenerSection(
                    project: key, rows: sections[existing].rows + [row])
            } else {
                indexOfSection[key] = sections.count
                sections.append(ListenerSection(project: key, rows: [row]))
            }
        }
        return sections
    }
}
