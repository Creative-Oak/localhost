import LocalhostKit
import SwiftUI

struct ListenerRowView: View {
    let row: ListenerPresentation

    private var process: ProcessIdentity { row.listener.process }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(row.listener.port))
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(process.isOurs ? .primary : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(row.label ?? process.name)
                        .fontWeight(row.label == nil ? .regular : .medium)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if row.listener.isExposed {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Bound to all interfaces — reachable from your network")
                    }
                }

                if let secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The second line never repeats the first.
    private var secondary: String? {
        if let advice = row.advice { return advice }
        if row.label != nil { return "\(process.name) · \(process.pid)" }
        if !process.isOurs { return "another user · \(process.pid)" }
        return "pid \(process.pid)"
    }

    /// Everything the row could not fit, so nothing is only truncated.
    private var tooltip: String {
        var lines = ["\(process.name) · pid \(process.pid)"]
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
        parts.append(process.name)
        if row.listener.isExposed { parts.append("reachable from your network") }
        return parts.joined(separator: ", ")
    }
}
