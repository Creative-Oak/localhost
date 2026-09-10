import LocalhostKit
import SwiftUI

/// The heading over a project's rows.
///
/// Nobody configured this group — it exists because those rows resolved to the
/// same project. So the heading claims nothing beyond that, and the only action
/// it offers is one we can already perform on every row individually.
struct SectionHeaderView: View {
    let section: ListenerSection
    var onQuitAll: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(section.project ?? "")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            if let branch = section.branch {
                Text(branch)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("\(section.rows.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer(minLength: 0)
            if !section.terminableRows.isEmpty {
                Button("Quit all", action: onQuitAll)
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Project \(section.project ?? ""), \(section.rows.count) listeners")
    }
}
