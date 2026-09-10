import LocalhostKit
import SwiftUI

public struct MenuContent: View {
    @State private var store: ListenerStore
    /// Height of the row list, measured rather than assumed.
    @State private var contentHeight: CGFloat = 0
    @State private var showsBackground = false
    @State private var query = ""
    @State private var selection: Listener.ID?
    @State private var pending: PendingTermination?
    @FocusState private var searchFocused: Bool

    /// Drives refreshes only when the panel is really on screen; the renderer
    /// seeds its own data and must not start a scan loop.
    private let scans: Bool
    /// Past this the list scrolls. `.infinity` draws every row, which is what
    /// the headless renderer wants.
    private let maximumListHeight: CGFloat

    public init(
        store: ListenerStore = ListenerStore(),
        scans: Bool = true,
        maximumListHeight: CGFloat = 520
    ) {
        _store = State(initialValue: store)
        self.scans = scans
        self.maximumListHeight = maximumListHeight
    }

    /// One confirmation path, so quitting one process and quitting a project
    /// cannot drift apart.
    private enum PendingTermination: Identifiable {
        case one(ListenerPresentation)
        case project(ListenerSection)

        var id: String {
            switch self {
            case let .one(row): return "one-\(row.id.pid)-\(row.id.port)"
            case let .project(section): return "project-\(section.id)"
            }
        }

        var rows: [ListenerPresentation] {
            switch self {
            case let .one(row): return [row]
            case let .project(section): return section.terminableRows
            }
        }

        var title: String {
            switch self {
            case let .one(row): return "Quit \(row.terminationDescription)?"
            case let .project(section):
                let count = section.terminableRows.count
                return "Quit \(count) process\(count == 1 ? "" : "es") in \(section.project ?? "this project")?"
            }
        }

        /// A bulk action names every process it will signal. The blast radius
        /// is larger than one row, so it is spelled out rather than counted.
        var detail: String {
            switch self {
            case .one:
                return "Quit asks it to stop and lets it shut down cleanly. Force quit does not."
            case let .project(section):
                let names = section.terminableRows
                    .map { "\($0.listener.port) \($0.listener.process.name)" }
                    .joined(separator: "\n")
                let skipped = section.rows.count - section.terminableRows.count
                let note = skipped > 0
                    ? "\n\n\(skipped) other listener\(skipped == 1 ? "" : "s") in this project belong to another user and will be left alone."
                    : ""
                return names + note
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            search

            if !store.oracle.isTrustworthy, store.hasScanned {
                degradedBanner
            }

            switch ListenerSearch.answer(for: query, rows: store.rows) {
            case let .free(port):
                answer("\(port) is free", symbol: "checkmark.circle.fill", tint: .green)
            case let .taken(row):
                takenAnswer(row)
            case .notAPort:
                if sections.isEmpty, background.isEmpty {
                    emptyState
                } else {
                    list
                }
            }

            if !background.isEmpty {
                backgroundDisclosure
            }

            if let message = store.actionError {
                actionErrorBanner(message)
            }

            Divider()
            footer
        }
        .frame(width: 340)
        // Keyboard-first: move with the arrows, act with Return, without ever
        // leaving the search field.
        .onKeyPress(.upArrow) { move(by: -1); return .handled }
        .onKeyPress(.downArrow) { move(by: 1); return .handled }
        .onKeyPress(.return) { openSelected() }
        // Escape clears a query first and dismisses the panel only when there
        // is nothing to clear, so a typed search is never lost with the window.
        .onKeyPress(.escape) {
            guard !query.isEmpty else { return .ignored }
            query = ""
            selection = nil
            return .handled
        }
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("Quit", role: .destructive) { confirm(using: .terminate) }
            Button("Force Quit", role: .destructive) { confirm(using: .force) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(pending?.detail ?? "")
        }
        // Scanning is tied to the lifetime of this view, so it runs while the
        // menu is open and stops the moment it closes. No background polling.
        .task { if scans { await store.refreshUntilCancelled() } }
    }

    // MARK: - Rows

    private var listed: [ListenerPresentation] {
        ListenerSearch.filter(store.rows.filter { $0.prominence == .listed }, query: query)
    }

    private var background: [ListenerPresentation] {
        ListenerSearch.filter(store.rows.filter { $0.prominence == .background }, query: query)
    }

    private var sections: [ListenerSection] {
        ListenerGrouping.sections(from: listed)
    }

    /// Everything on screen, in the order the arrow keys should walk it.
    private var visible: [ListenerPresentation] {
        showsBackground ? listed + background : listed
    }

    /// A scroll view appears only once the rows genuinely overflow.
    ///
    /// `ScrollView` reports no intrinsic height, so wrapping the list in one
    /// unconditionally collapses the panel to a single row inside
    /// `MenuBarExtra`'s window sizing. The rows are therefore laid out and
    /// measured first, and only wrapped when the measurement says they must be.
    @ViewBuilder
    private var list: some View {
        if contentHeight > maximumListHeight {
            ScrollView { measuredRows }
                .frame(height: maximumListHeight)
        } else {
            measuredRows
        }
    }

    private var measuredRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                if section.project != nil {
                    SectionHeaderView(section: section) { pending = .project(section) }
                }
                ForEach(section.rows) { row in
                    ListenerRowView(
                        row: row,
                        isSelected: row.id == selection,
                        inGroup: section.project != nil
                    ) { action in
                        perform(action, on: row)
                    }
                    .padding(.leading, section.project == nil ? 0 : 10)
                }
            }
            if showsBackground {
                ForEach(background) { row in
                    ListenerRowView(row: row, isSelected: row.id == selection) { action in
                        perform(action, on: row)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
        }
    }

    // MARK: - Actions

    private func perform(_ action: ListenerAction, on row: ListenerPresentation) {
        selection = row.id
        guard action != .terminate else {
            // The only irreversible action, so it never happens on one click.
            pending = .one(row)
            return
        }
        ActionRunner.perform(action, on: row)
    }

    private func confirm(using signal: ProcessTerminator.Signal) {
        guard let rows = pending?.rows, !rows.isEmpty else { return }
        pending = nil
        Task { await store.terminate(rows, using: signal) }
    }

    private func move(by offset: Int) {
        let rows = visible
        guard !rows.isEmpty else { return }
        guard let current = selection, let index = rows.firstIndex(where: { $0.id == current }) else {
            selection = rows.first?.id
            return
        }
        selection = rows[min(max(index + offset, 0), rows.count - 1)].id
    }

    private func openSelected() -> KeyPress.Result {
        guard let selection, let row = visible.first(where: { $0.id == selection }) else {
            guard let first = visible.first else { return .ignored }
            self.selection = first.id
            perform(.openInBrowser, on: first)
            return .handled
        }
        guard row.supports(.openInBrowser) else { return .ignored }
        perform(.openInBrowser, on: row)
        return .handled
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("Listening")
                .font(.headline)
            Spacer()
            if store.hasScanned {
                Text("\(listed.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Port, project or process", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search by port, project or process")
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        // Keyboard-first: the panel opens ready to be typed into.
        .onAppear { searchFocused = true }
    }

    private func answer(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fontWeight(.medium)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    /// The point of the whole search field: a port you want, and the one thing
    /// standing in the way of having it.
    private func takenAnswer(_ row: ListenerPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text("\(row.listener.port) is taken by \(row.label ?? row.listener.process.name)")
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            ListenerRowView(row: row, isSelected: false) { action in
                perform(action, on: row)
            }
            .padding(.horizontal, -12)

            if row.canTerminate {
                Button("Free port \(String(row.listener.port))") { pending = .one(row) }
                    .controlSize(.small)
            } else {
                // Being honest about the limit is better than a button that
                // always fails: v1 signals only your own processes.
                Text("It belongs to another user, so Localhost cannot free it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "Port \(row.listener.port) belongs to another user and cannot be freed.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Folded away, never hidden: telling someone nothing is on 44950 when
    /// something is would be worse than the clutter.
    private var backgroundDisclosure: some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { showsBackground.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showsBackground ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                Text(showsBackground
                     ? "Hide background services"
                     : "\(background.count) background services")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Services on ports nobody chose — high, operating-system-assigned ports")
        .accessibilityLabel(showsBackground
            ? "Hide background services"
            : "Show \(background.count) background services")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var emptyState: some View {
        Text(emptyMessage)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
    }

    private var emptyMessage: String {
        if !store.hasScanned { return "Scanning…" }
        if !query.isEmpty { return "Nothing matches \"\(query)\"." }
        if case .failed = store.oracle { return "Could not read the port table." }
        return "Nothing is listening."
    }

    /// Says what is missing and why, because a shorter list is otherwise
    /// indistinguishable from a quiet machine.
    private var degradedBanner: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(degradedHeadline).font(.caption).fontWeight(.medium)
                Text(degradedDetail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(degradedHeadline). \(degradedDetail)")
    }

    private var degradedHeadline: String {
        if case .failed = store.oracle { return "Port discovery failed" }
        return "Showing your own processes only"
    }

    private var degradedDetail: String {
        switch store.oracle {
        case .verified:
            return ""
        case .degraded:
            // The private-struct parse stopped agreeing with libproc, so
            // listeners owned by other users cannot be trusted or named.
            return "macOS may have changed since this version shipped. Listeners owned by other users are hidden."
        case let .failed(reason):
            return reason
        }
    }

    private func actionErrorBanner(_ message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).lineLimit(2)
            Spacer(minLength: 0)
            Button {
                store.dismissActionError()
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.1))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // Surfaced rather than logged: if the private-struct parse ever
            // stops agreeing with libproc, the rows are still real but
            // listeners we do not own may be missing or unnamed.
            if !store.oracle.isTrustworthy {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(oracleExplanation)
                Text("Limited results")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var oracleExplanation: String {
        switch store.oracle {
        case .verified: return ""
        case let .degraded(reason): return "Showing your own processes only. \(reason)"
        case let .failed(reason): return "Port discovery failed. \(reason)"
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
