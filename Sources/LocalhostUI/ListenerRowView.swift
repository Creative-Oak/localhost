import LocalhostKit
import SwiftUI

public struct ListenerRowView: View {
    let row: ListenerPresentation
    var isSelected: Bool = false
    /// Inside a project group the heading already carries the project name and
    /// branch, so the row says what it *is* instead of repeating them.
    var inGroup: Bool = false
    var onAction: (ListenerAction) -> Void = { _ in }

    public init(
        row: ListenerPresentation,
        isSelected: Bool = false,
        inGroup: Bool = false,
        onAction: @escaping (ListenerAction) -> Void = { _ in }
    ) {
        self.row = row
        self.isSelected = isSelected
        self.inGroup = inGroup
        self.onAction = onAction
    }

    /// On a highlighted row every piece of text turns light, the way a system
    /// menu does it. Leaving the second line `.secondary` puts grey on the
    /// selection blue, which fails contrast and looks unfinished.
    private var secondaryStyle: AnyShapeStyle {
        isSelected
            ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor).opacity(0.8))
            : AnyShapeStyle(.secondary)
    }

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
                .foregroundStyle(process.isOurs
                    ? (isSelected
                        ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor))
                        : AnyShapeStyle(.primary))
                    : secondaryStyle)

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
                            .foregroundStyle(isSelected
                                ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor))
                                : AnyShapeStyle(Color(nsColor: .systemOrange)))
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
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(
            // The highlight menus actually use, inset from the panel edge the
            // way NSMenu insets its own rows.
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                .padding(.horizontal, 5)
        )
        .foregroundStyle(isSelected ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.primary))
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
