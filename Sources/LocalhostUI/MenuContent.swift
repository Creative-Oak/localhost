import LocalhostKit
import SwiftUI

public struct MenuContent: View {
    @State private var store: ListenerStore
    /// Height of the row list, measured rather than assumed.
    @State private var contentHeight: CGFloat = 0
    @State private var expanded: Set<ListenerPresentation.Prominence> = []
    /// A tier just opened, waiting for the list to be re-measured so it can be
    /// scrolled into view.
    @State private var revealing: ListenerPresentation.Prominence?
    @State private var query = ""
    @State private var selection: Listener.ID?
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
        maximumListHeight: CGFloat = 520,
        initialSelection: Listener.ID? = nil,
        highlightFooter: Bool = false,
        initiallyExpanded: Set<ListenerPresentation.Prominence> = [],
        forceHoverOn: Listener.ID? = nil
    ) {
        _store = State(initialValue: store)
        self.scans = scans
        self.maximumListHeight = maximumListHeight
        _selection = State(initialValue: initialSelection)
        _expanded = State(initialValue: initiallyExpanded)
        self.highlightFooter = highlightFooter
        self.forceHoverOn = forceHoverOn
    }

    private let highlightFooter: Bool
    private let forceHoverOn: Listener.ID?
    /// Expands every tier a moment after appearing, so a screenshot can show
    /// the window growing to fit — the one thing a static render cannot.
    public var expandsAfterAppearing = false

    /// One confirmation path, so quitting one process and quitting a project
    /// cannot drift apart.
    private enum PendingTermination {
        case one(ListenerPresentation)
        case project(ListenerSection)

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
                if hasNothingToShow {
                    emptyState
                } else {
                    list
                }
            }

            if let message = store.actionError {
                actionErrorBanner(message)
            }

            Divider()
            footer
        }
        .frame(width: 340)
        // Always the content's own height, never squeezed to the window's:
        // the window follows the content, not the other way round.
        .fixedSize(horizontal: false, vertical: true)
        // Rows highlight edge to edge, so near the panel's rounded corner a
        // highlight would otherwise draw past the window's shape and onto the
        // desktop. Clipping the content — and only the content — keeps
        // highlights inside a rounded shape while the material below stays
        // square and is shaped by the window itself. The radius is deliberately
        // smaller than the system's, because clipping content more tightly than
        // the window is invisible, whereas clipping it wider leaves a gap.
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .background(VisualEffectBackground())
        .background(GeometryReader { proxy in WindowFitter(height: proxy.size.height) })
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
        // Scanning is tied to the lifetime of this view, so it runs while the
        // menu is open and stops the moment it closes. No background polling.
        .task { if scans { await store.refreshUntilCancelled() } }
        .onAppear { if scans { Updates.checkIfDue() } }
        .task {
            guard expandsAfterAppearing else { return }
            try? await Task.sleep(for: .seconds(0.8))
            withAnimation(.snappy(duration: 0.18)) { expanded = [.application, .system] }
            revealing = .system
        }
    }

    // MARK: - Rows

    private func rows(_ prominence: ListenerPresentation.Prominence) -> [ListenerPresentation] {
        ListenerSearch.filter(store.rows.filter { $0.prominence == prominence }, query: query)
    }

    private var yours: [ListenerPresentation] { rows(.devServer) }

    /// A search reaches every tier. Hiding a match behind a disclosure would
    /// mean saying "nothing matches 5000" while AirPlay sits on it.
    private func reveals(_ prominence: ListenerPresentation.Prominence) -> Bool {
        expanded.contains(prominence) || !query.isEmpty
    }

    /// The tiers that fold away, in the order they appear beneath the list.
    private var foldedTiers: [(prominence: ListenerPresentation.Prominence, title: String, help: String)] {
        [
            (.application, "Applications",
             "Applications of yours that happen to listen — launchers, sync clients, editor helpers"),
            (.system, "System",
             "Daemons, launchd-held sockets and processes belonging to other users"),
        ]
    }

    private var sections: [ListenerSection] {
        ListenerGrouping.sections(from: yours)
    }

    /// Everything on screen, in the order the arrow keys should walk it.
    private var visible: [ListenerPresentation] {
        yours + foldedTiers.flatMap { reveals($0.prominence) ? rows($0.prominence) : [] }
    }

    /// Nothing in any tier, rather than nothing in the first one. Hiding the
    /// tier headings whenever no dev server was running left a quiet machine
    /// with no way to reach its applications or system listeners at all.
    private var hasNothingToShow: Bool {
        visible.isEmpty && foldedTiers.allSatisfy { rows($0.prominence).isEmpty }
    }

    /// The screen decides how tall the list may get, so a long list scrolls
    /// rather than running off a small display. `.infinity` is left alone: the
    /// headless renderer asks for every row.
    private var listLimit: CGFloat {
        maximumListHeight.isFinite ? min(maximumListHeight, NSScreen.listHeightLimit) : .infinity
    }

    /// A scroll view appears only once the rows genuinely overflow.
    ///
    /// `ScrollView` reports no intrinsic height, so wrapping the list in one
    /// unconditionally collapses the panel to a single row inside
    /// `MenuBarExtra`'s window sizing. The rows are therefore laid out and
    /// measured first, and only wrapped when the measurement says they must be.
    ///
    /// Once it scrolls, the list follows two things off-screen: a tier that was
    /// just opened, whose rows would otherwise appear below the fold as if the
    /// click did nothing, and the selection as the arrow keys move it.
    private var list: some View {
        ScrollViewReader { proxy in
            Group {
                if contentHeight > listLimit {
                    ScrollView { measuredRows }
                        .frame(height: listLimit)
                } else {
                    measuredRows
                }
            }
            .onChange(of: contentHeight) {
                guard let tier = revealing else { return }
                revealing = nil
                // A turn later, so a scroll view that has only just appeared
                // has laid out its content.
                DispatchQueue.main.async {
                    withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(tierAnchor(tier), anchor: .top) }
                }
            }
            .onChange(of: selection) {
                guard let selection else { return }
                withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(selection) }
            }
        }
    }

    private func tierAnchor(_ prominence: ListenerPresentation.Prominence) -> String {
        "tier-\(prominence)"
    }

    private var measuredRows: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            if yours.isEmpty, query.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            ForEach(sections) { section in
                if section.project != nil {
                    SectionHeaderView(section: section) {
                        requestTermination(.project(section))
                    }
                }
                ForEach(section.rows) { row in
                    ListenerRowView(
                        row: row,
                        isSelected: row.id == selection,
                        inGroup: section.project != nil,
                        forceHovered: row.id == forceHoverOn
                    ) { action in
                        perform(action, on: row)
                    }
                    .padding(.leading, section.project == nil ? 0 : 10)
                    .id(row.id)
                }
            }
            ForEach(foldedTiers, id: \.prominence) { tier in
                if !rows(tier.prominence).isEmpty {
                    tierHeading(for: tier.prominence, title: tier.title, help: tier.help)
                        .id(tierAnchor(tier.prominence))
                    if reveals(tier.prominence) {
                        ForEach(rows(tier.prominence)) { row in
                            ListenerRowView(
                                row: row,
                                isSelected: row.id == selection,
                                forceHovered: row.id == forceHoverOn
                            ) { action in
                                perform(action, on: row)
                            }
                            .id(row.id)
                        }
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
            requestTermination(.one(row))
            return
        }
        ActionRunner.perform(action, on: row)
    }

    /// Confirm, then act — in one place, so quitting one process and quitting
    /// a project cannot diverge.
    private func requestTermination(_ target: PendingTermination) {
        let rows = target.rows
        guard !rows.isEmpty else { return }
        guard let signal = AppServices.confirmTermination(
            title: target.title, detail: target.detail) else { return }
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
                Text("\(yours.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            settingsMenu
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Everything that is not about ports lives here, so the panel stays a
    /// list rather than growing a settings screen.
    private var settingsMenu: some View {
        Menu {
            Toggle("Open at Login", isOn: Binding(
                get: { AppServices.opensAtLogin },
                set: { AppServices.opensAtLogin = $0 }))
            Toggle("Check for Updates Automatically", isOn: Binding(
                get: { Updates.checksAutomatically },
                set: { Updates.checksAutomatically = $0 }))
            Button("Check for Updates…") { Updates.checkForUpdates() }
            Divider()
            Button("About Localhost") { AppServices.showAbout() }
            Button("Contact Support…") { AppServices.contactSupport() }
        } label: {
            Image(systemName: "gearshape")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .accessibilityLabel("Settings")
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
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Metrics.controlCornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.6))
        )
        .padding(.horizontal, 10)
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
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
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
                Button("Free port \(String(row.listener.port))") { requestTermination(.one(row)) }
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

    /// A tier heading, in the same language as a project heading.
    ///
    /// These were sentences — "7 applications" — in a row at the foot of the
    /// panel, which read as footnotes rather than as structure. Tabs were the
    /// other candidate and lose on search: typing 5000 has to find AirPlay
    /// wherever it lives, and a tab bar either contradicts itself or switches
    /// under you. A heading keeps the count visible, keeps search coherent,
    /// and matches how menus organise themselves.
    private func tierHeading(
        for prominence: ListenerPresentation.Prominence,
        title: String,
        help: String
    ) -> some View {
        let count = rows(prominence).count
        let shown = reveals(prominence)
        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                if expanded.contains(prominence) {
                    expanded.remove(prominence)
                } else {
                    expanded.insert(prominence)
                    revealing = prominence
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .rotationEffect(.degrees(shown ? 90 : 0))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(title), \(count) listeners")
        .accessibilityHint(shown ? "Collapse" : "Expand")
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
        return "No development servers running."
    }

    /// Says what is missing and why, because a shorter list is otherwise
    /// indistinguishable from a quiet machine.
    private var degradedBanner: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
            VStack(alignment: .leading, spacing: 2) {
                Text(degradedHeadline).font(.caption).fontWeight(.medium)
                Text(degradedDetail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .systemOrange).opacity(0.12))
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
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
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
        .background(Color(nsColor: .systemOrange).opacity(0.12))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuActionRow(
                title: "Quit Localhost",
                symbol: "power",
                forceHighlighted: highlightFooter
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Shared geometry, so the panel and its rows round consistently.
enum Metrics {
    /// Deliberately rounder than the panel appears to be. Erring high only
    /// pulls content inward; erring low lets it escape the window's shape.
    static let panelCornerRadius: CGFloat = 20
    /// Vertical gap between rows, so two highlighted rows read as two things
    /// rather than one block of colour.
    static let rowSpacing: CGFloat = 2
    /// macOS 26's menus are much rounder than the 5pt of older releases, and a
    /// tight highlight inside a very round panel reads as a mismatch.
    static let rowCornerRadius: CGFloat = 8
    static let controlCornerRadius: CGFloat = 8
    /// How far a highlight sits in from the panel edge. Generous on purpose:
    /// a fill that runs close to the edge reads as a banner rather than as a
    /// row, and leaves the panel looking heavier than it is.
    static let rowInset: CGFloat = 9
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
