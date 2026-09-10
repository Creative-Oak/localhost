import LocalhostKit
import SwiftUI

struct MenuContent: View {
    @State private var store = ListenerStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if store.rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.rows) { row in
                            ListenerRowView(row: row)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 380)
            }

            Divider()
            footer
        }
        .frame(width: 340)
        // Scanning is tied to the lifetime of this view, so it runs while the
        // menu is open and stops the moment it closes. No background polling.
        .task { await store.refreshUntilCancelled() }
    }

    private var header: some View {
        HStack {
            Text("Listening")
                .font(.headline)
            Spacer()
            if store.hasScanned {
                Text("\(store.rows.count)")
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
