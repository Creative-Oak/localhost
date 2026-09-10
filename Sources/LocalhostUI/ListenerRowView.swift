import LocalhostKit
import SwiftUI

public struct ListenerRowView: View {
    let row: ListenerPresentation
    var isSelected: Bool = false
    /// Inside a project group the heading already carries the project name and
    /// branch, so the row says what it *is* instead of repeating them.
    var inGroup: Bool = false
    /// Forces the hover appearance. Hover cannot be triggered in a headless
    /// screenshot, and hover-versus-selection is precisely what needs looking at.
    var forceHovered = false
    var onAction: (ListenerAction) -> Void = { _ in }

    @State private var hovering = false

    private var isHovered: Bool { hovering || forceHovered }

    /// Hover and selection are different states and must look different.
    ///
    /// Sharing one appearance meant the pointer resting on one row while
    /// another was selected lit up both in full accent blue, which reads as two
    /// selections and makes a short list look loud. macOS already has the
    /// vocabulary: the accent fill means "this is selected", and the
    /// unemphasized fill means "this is merely under the pointer".
    private enum Emphasis { case none, hover, selected }

    private var emphasis: Emphasis {
        if isSelected { return .selected }
        return isHovered ? .hover : .none
    }

    /// Actions appear for either state — the pointer is how they are reached.
    private var showsActions: Bool { emphasis != .none }

    /// Both states are light, so text keeps its ordinary colours and the row
    /// keeps its hierarchy. A solid accent fill under two lines of text — a
    /// project, a branch, a framework, a version — flattens all of it to white
    /// and makes a two-row list look like a dialog. A tint says "selected"
    /// without shouting, and the accent-versus-grey difference still separates
    /// selection from hover.
    private var fill: Color {
        switch emphasis {
        case .none:
            return .clear
        case .hover:
            return Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.7)
        case .selected:
            return Color(nsColor: .controlAccentColor).opacity(0.18)
        }
    }

    public init(
        row: ListenerPresentation,
        isSelected: Bool = false,
        inGroup: Bool = false,
        forceHovered: Bool = false,
        onAction: @escaping (ListenerAction) -> Void = { _ in }
    ) {
        self.row = row
        self.isSelected = isSelected
        self.inGroup = inGroup
        self.forceHovered = forceHovered
        self.onAction = onAction
    }

    /// Shown inline on the highlighted row. Quitting is not among them: it is
    /// irreversible and belongs behind the context menu and a confirmation.
    private static let quickActions: [ListenerAction] = [
        .openInBrowser, .openInTerminal, .revealInFinder,
    ]

    /// Secondary text keeps its own colour: neither state is dark enough to
    /// need light text, which is the point of tinting rather than filling.
    private var secondaryStyle: AnyShapeStyle { AnyShapeStyle(.secondary) }

    /// The first line: what this row is, without repeating its heading.
    private var primary: String {
        if inGroup { return row.runtime?.description ?? process.name }
        return row.label ?? process.name
    }

    private var process: ProcessIdentity { row.listener.process }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(row.listener.port))
                // Tabular figures in the system face, not SF Mono: the columns
                // still align, but the panel reads as a system menu rather
                // than as a code editor.
                .font(.body.monospacedDigit())
                .fontWeight(.medium)
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(process.isOurs ? AnyShapeStyle(.primary) : secondaryStyle)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(primary)
                        // Regular weight throughout, as system menus use.
                        // Hierarchy comes from the dimmer, smaller second line
                        // rather than from bolding the first.
                        .fontWeight(.regular)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let branch = row.branch, !inGroup {
                        Text(branch)
                            .foregroundStyle(secondaryStyle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if row.isExposedDevServer {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.caption2)
                            // The system orange, so it stays correct in dark
                            // mode and under Increase Contrast — but on the
                            // selection fill it becomes light like everything else.
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .help("Bound to all interfaces — reachable from your network")
                    }
                }

                if let secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(secondaryStyle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)

            // Nothing previously suggested a row was clickable, and the
            // useful destinations — the browser, a terminal, the folder —
            // were buried in a context menu nobody had reason to try.
            if showsActions {
                HStack(spacing: 2) {
                    ForEach(Self.quickActions.filter(row.supports), id: \.self) { action in
                        Button {
                            onAction(action)
                        } label: {
                            Image(systemName: action.symbol)
                                .font(.caption)
                                .frame(width: 20, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(action.title)
                        .accessibilityLabel(action.title)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(
            // The highlight menus actually use, inset from the panel edge the
            // way NSMenu insets its own rows.
            RoundedRectangle(cornerRadius: Metrics.rowCornerRadius, style: .continuous)
                .fill(fill)
                .padding(.horizontal, Metrics.rowInset)
        )
        .foregroundStyle(.primary)
        .onHover { inside in
            hovering = inside
            // A pointing hand is the system's own signal that something opens.
            if row.supports(.openInBrowser) {
                inside ? NSCursor.pointingHand.push() : NSCursor.pop()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if row.supports(.openInBrowser) { onAction(.openInBrowser) }
        }
        .contextMenu {
            ForEach(row.availableActions, id: \.self) { action in
                Button {
                    onAction(action)
                } label: {
                    Label(action.title, systemImage: action.symbol)
                }
                // The submenu doubles as the preference: whichever app is
                // picked here becomes the default for every row afterwards.
                if action == .openInBrowser {
                    Menu("Open in Browser…") {
                        ForEach(ExternalApps.browsers()) { browser in
                            Button(browser.name) { ActionRunner.open(row, inBrowser: browser) }
                        }
                    }
                }
                if action == .openInTerminal {
                    Menu("Open in Terminal…") {
                        ForEach(ExternalApps.terminals()) { terminal in
                            Button(terminal.name) { ActionRunner.open(row, inTerminal: terminal) }
                        }
                    }
                }
            }
        }
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(row.supports(.openInBrowser)
            ? "Opens http://localhost:\(row.listener.port)"
            : "")
        .accessibilityAddTraits(row.supports(.openInBrowser) ? .isButton : [])
    }

    /// The second line never repeats the first.
    private var secondary: String? {
        if let advice = row.advice { return advice }
        // The runtime is already the first line here, and for something like
        // Python the runtime and the process share a name.
        if inGroup {
            return primary == process.name
                ? "pid \(process.pid)"
                : "\(process.name) · \(process.pid)"
        }
        if case let .container(container) = row.attribution {
            return container.image.isEmpty ? "container" : container.image
        }
        // "Next.js 16.2.12" says more than "node", and we paid nothing for it.
        if let runtime = row.runtime, row.label != nil {
            return "\(runtime) · \(process.pid)"
        }
        if row.label != nil { return "\(process.name) · \(process.pid)" }
        if let runtime = row.runtime, process.isOurs {
            return "\(runtime) · \(process.pid)"
        }
        // The primary line is already the process name here, so say who owns it
        // rather than repeating it. "another user · 1" was true and unhelpful.
        if !process.isOurs { return process.uid == 0 ? "root" : "uid \(process.uid)" }
        return "pid \(process.pid)"
    }

    /// Everything the row could not fit, so nothing is only truncated.
    private var tooltip: String {
        var lines = ["\(process.name) · pid \(process.pid)"]
        if let runtime = row.runtime { lines.append(String(describing: runtime)) }
        lines.append(row.listener.addresses.joined(separator: ", ") + ":\(row.listener.port)")
        if let advice = row.advice { lines.append(advice) }
        if case let .project(_, root, source) = row.attribution {
            lines.append("\(root.path) (\(source.rawValue))")
        }
        return lines.joined(separator: "\n")
    }

    private var accessibilityLabel: String {
        var parts = ["Port \(row.listener.port)"]
        if let label = row.label { parts.append(label) }
        if let branch = row.branch { parts.append("branch \(branch)") }
        if let runtime = row.runtime { parts.append(runtime.description) }
        parts.append(process.name)
        if !process.isOurs { parts.append("owned by another user") }
        if row.isExposedDevServer { parts.append("reachable from your network") }
        return parts.joined(separator: ", ")
    }
}

extension ListenerPresentation {
    /// Worth warning about only when it is something you started.
    ///
    /// "Ours" is not enough of a test: AirPlay and Remote Desktop run as the
    /// logged-in user and bind wildcard addresses as a matter of course, so
    /// including them lit up most of the list and trained the reader to ignore
    /// the indicator. A known daemon on every interface is expected; your own
    /// dev server on every interface is the news.
    var isExposedDevServer: Bool {
        guard listener.isExposed, listener.process.isOurs else { return false }
        if case .knownDaemon = attribution { return false }
        return true
    }
}
