import LocalhostKit
import SwiftUI

public struct MenuContent: View {
    @State private var store: ListenerStore
    /// Height of the row list, measured rather than assumed.
    @State private var contentHeight: CGFloat = 0
    @State private var showsBackground = false
    @State private var query = ""
    @State private var selection: Listener.ID?
    @State private var pendingTermination: ListenerPresentation?
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

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            search

            if let freePort {
                answer("\(freePort) is free", symbol: "checkmark.circle.fill", tint: .green)
            } else if listed.isEmpty, background.isEmpty {
                emptyState
            } else {
                list
            }

            if !background.isEmpty {
                backgroundDisclosure
            }

            if let message = store.actionError {
                actionError(message)
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
        .confirmationDialog(
            pendingTermination.map { "Quit \($0.terminationDescription)?" } ?? "",
            isPresented: Binding(
                get: { pendingTermination != nil },
                set: { if !$0 { pendingTermination = nil } }),
            titleVisibility: .visible
        ) {
            Button("Quit Process", role: .destructive) {
                guard let row = pendingTermination else { return }
                pendingTermination = nil
                Task { await store.terminate(row, using: .terminate) }
            }
            Button("Force Quit", role: .destructive) {
                guard let row = pendingTermination else { return }
                pendingTermination = nil
                Task { await store.terminate(row, using: .force) }
            }
            Button("Cancel", role: .cancel) { pendingTermination = nil }
        } message: {
            Text("Quit asks it to stop and lets it shut down cleanly. Force quit does not.")
        }
        // Scanning is tied to the lifetime of this view, so it runs while the
        // menu is open and stops the moment it closes. No background polling.
        .task { if scans { await store.refreshUntilCancelled() } }
    }

    /// A scroll view appears only once the rows genuinely overflow.
    ///
    /// `ScrollView` reports no intrinsic height, so wrapping the list in one
    /// unconditionally collapses the panel to a single row inside
    /// `MenuBarExtra`'s window sizing. The rows are therefore laid out and
    /// measured first, and only wrapped when the measurement says they must be.
    /// A `LazyVStack` would defeat this: inside a collapsed scroll view it
    /// builds one row and reports that as the height.
    @ViewBuilder
    private var list: some View {
        if contentHeight > maximumListHeight {
            ScrollView { measuredRows }
                .frame(height: maximumListHeight)
        } else {
            measuredRows
        }
    }

    private var listed: [ListenerPresentation] {
        ListenerSearch.filter(store.rows.filter { $0.prominence == .listed }, query: query)
    }

    private var background: [ListenerPresentation] {
        ListenerSearch.filter(store.rows.filter { $0.prominence == .background }, query: query)
    }

    /// A port the query names that nothing holds. This is an answer, not an
    /// empty result, so it gets said out loud.
    private var freePort: UInt16? {
        ListenerSearch.freePort(in: query, rows: store.rows)
    }

    /// Everything on screen, in the order the arrow keys should walk it.
    private var visible: [ListenerPresentation] {
        showsBackground ? listed + background : listed
    }

    private func perform(_ action: ListenerAction, on row: ListenerPresentation) {
        selection = row.id
        guard action != .terminate else {
            // The only irreversible action, so it never happens on one click.
            pendingTermination = row
            return
        }
        ActionRunner.perform(action, on: row)
    }

    private func move(by offset: Int) {
        let rows = visible
        guard !rows.isEmpty else { return }
        guard let current = selection, let index = rows.firstIndex(where: { $0.id == current }) else {
            selection = rows.first?.id
            return
        }
        let next = min(max(index + offset, 0), rows.count - 1)
        selection = rows[next].id
    }

    private func openSelected() -> KeyPress.Result {
        // With a port typed and nothing holding it, Return has nothing to open.
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

    private func actionError(_ message: String) -> some View {
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

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Port, project or process", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
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

    private var measuredRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visible) { row in
                ListenerRowView(row: row, isSelected: row.id == selection) { action in
                    perform(action, on: row)
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
    }

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

    private func answer(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
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
        return "Nothing is listening."
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
        case .verified:
            return ""
        case let .degraded(reason):
            return "Showing your own processes only. \(reason)"
        case let .failed(reason):
            return "Port discovery failed. \(reason)"
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
