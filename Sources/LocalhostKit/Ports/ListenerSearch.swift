import Foundation

/// Matching a typed query against rows.
///
/// The important case is the one that returns nothing. Typing `3000` when
/// nothing holds it should answer the question — "3000 is free" — rather than
/// showing an empty list, which looks the same as a broken scan.
public enum ListenerSearch {
    public static func filter(
        _ rows: [ListenerPresentation],
        query: String
    ) -> [ListenerPresentation] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { matches($0, needle: needle) }
    }

    static func matches(_ row: ListenerPresentation, needle: String) -> Bool {
        if String(row.listener.port).hasPrefix(needle) { return true }
        if let label = row.label, label.lowercased().contains(needle) { return true }
        if row.listener.process.name.lowercased().contains(needle) { return true }
        if let runtime = row.runtime, runtime.description.lowercased().contains(needle) { return true }
        if let branch = row.branch, branch.lowercased().contains(needle) { return true }
        return false
    }

    /// The port a query names, when the query is only a port number.
    ///
    /// Deliberately strict: `300` is a prefix search, not a claim about port
    /// 300, so only a value that is already a plausible port counts.
    public static func port(in query: String) -> UInt16? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return nil }
        guard let value = UInt16(trimmed), value > 0 else { return nil }
        return value
    }

    /// Whether the query names a port that nothing is listening on.
    public static func freePort(in query: String, rows: [ListenerPresentation]) -> UInt16? {
        guard case .free(let port) = answer(for: query, rows: rows) else { return nil }
        return port
    }

    /// The direct answer to "what about port N?".
    ///
    /// Typing a port is a question, and all three answers are useful: it is
    /// free, something of yours has it and can be moved aside, or something
    /// that is not yours has it and cannot.
    public enum Answer: Hashable, Sendable {
        case free(UInt16)
        case taken(ListenerPresentation)
        /// The query was not a port at all, so there is nothing to answer.
        case notAPort
    }

    public static func answer(for query: String, rows: [ListenerPresentation]) -> Answer {
        guard let port = port(in: query) else { return .notAPort }
        // A process of ours is the more useful answer when several rows share a
        // port, because it is the one that can actually be moved aside.
        let holders = rows.filter { $0.listener.port == port }
        guard let holder = holders.first(where: { $0.canTerminate }) ?? holders.first else {
            return .free(port)
        }
        return .taken(holder)
    }
}
