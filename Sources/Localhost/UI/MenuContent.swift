import LocalhostKit
import SwiftUI

struct MenuContent: View {
    @State private var store: ListenerStore
    /// Height of the row list, measured rather than assumed.
    @State private var contentHeight: CGFloat = 0
    @State private var showsBackground = false
    /// Drives refreshes only when the panel is really on screen; the renderer
    /// seeds its own data and must not start a scan loop.
    private let scans: Bool
    /// Past this the list scrolls. `.infinity` draws every row, which is what
    /// the headless renderer wants.
    private let maximumListHeight: CGFloat

    init(
        store: ListenerStore = ListenerStore(),
        scans: Bool = true,
        maximumListHeight: CGFloat = 520
    ) {
        _store = State(initialValue: store)
        self.scans = scans
        self.maximumListHeight = maximumListHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if listed.isEmpty, background.isEmpty {
                emptyState
            } else {
                list
            }

            if !background.isEmpty {
                backgroundDisclosure
            }

            Divider()
            footer
        }
        .frame(width: 340)
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
        store.rows.filter { $0.prominence == .listed }
    }

    private var background: [ListenerPresentation] {
        store.rows.filter { $0.prominence == .background }
    }

    private var measuredRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(listed) { row in
                ListenerRowView(row: row)
            }
            if showsBackground {
                ForEach(background) { row in
                    ListenerRowView(row: row)
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

    @ViewBuilder
    private var emptyState: some View {
        Text(store.hasScanned ? "Nothing is listening." : "Scanning…")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
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
