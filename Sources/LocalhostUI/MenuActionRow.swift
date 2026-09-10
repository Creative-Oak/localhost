import AppKit
import SwiftUI

/// A full-width row that behaves like a menu item.
///
/// System menu bar extras put their actions in rows that highlight edge to
/// edge on hover — "Wi-Fi Settings…" at the bottom of the Wi-Fi menu. A small
/// right-aligned push button reads as a dialog control instead, which is what
/// this panel had.
struct MenuActionRow: View {
    let title: String
    var symbol: String?
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.caption)
                        .frame(width: 14)
                }
                Text(title)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHovered
                ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor))
                : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                    .padding(.horizontal, 5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
