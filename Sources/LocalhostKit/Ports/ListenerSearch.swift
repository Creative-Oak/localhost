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
        guard let port = port(in: query) else { return nil }
        guard !rows.contains(where: { $0.listener.port == port }) else { return nil }
        return port
    }
}
