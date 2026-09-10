import AppKit
import Foundation
import LocalhostKit
import ServiceManagement

/// The things an app has to do besides its job: start with the Mac, say what
/// version it is, take a licence key, and be reachable when it breaks.
@MainActor
public enum AppServices {
    /// Placeholder. Replace before release — this address does not exist.
    static let supportAddress = "support@magnisoft.dk"

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        default: return "unversioned"
        }
    }

    // MARK: - Launch at login

    /// A menu bar utility that does not come back after a restart gets deleted
    /// on the second day.
    static var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                present(
                    title: "Could not change the login setting",
                    message: "\(error.localizedDescription)\n\nYou can set this yourself in System Settings › General › Login Items.")
            }
        }
    }

    // MARK: - About

    static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Localhost",
            .applicationVersion: version,
            .init(rawValue: "Copyright"): "Copyright © 2026 Magnisoft.",
        ])
    }

    static func contactSupport(subject: String = "Localhost feedback") {
        // The version travels with the message, because "it's broken" and
        // "which version?" is a conversation nobody enjoys.
        let body = "\n\n---\nLocalhost \(version)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Licence entry

    /// An alert with a text field, rather than a settings window: this is a
    /// thing people do once.
    static func promptForLicense(into store: LicenseStore) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Enter your licence key"
        alert.informativeText = "Paste the key from your purchase email."
        alert.addButton(withTitle: "Activate")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 48))
        field.placeholderString = "LOCALHOST-…"
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch store.activate(field.stringValue) {
        case let .success(license):
            present(title: "Thank you", message: "Localhost is licensed to \(license.email).")
        case let .failure(failure):
            present(title: "That key was not accepted", message: failure.description)
        }
    }

    // MARK: - Crash reports

    /// Offers to send a crash report, and never sends one on its own.
    ///
    /// No analytics SDK and no automatic transmission: the app makes no network
    /// requests, and that claim is worth more than the crashes it would
    /// collect. macOS already writes the report; this only notices it and
    /// offers to hand it over.
    public static func offerPendingCrashReport(defaults: UserDefaults = .standard) {
        let seenKey = "lastSeenCrashReport"
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }

        let ours = entries
            .filter { $0.lastPathComponent.hasPrefix("Localhost-") }
            .sorted { left, right in
                (modified(left) ?? .distantPast) > (modified(right) ?? .distantPast)
            }
        guard let latest = ours.first,
              defaults.string(forKey: seenKey) != latest.lastPathComponent
        else { return }

        // Recorded before asking, so declining is not re-asked every launch.
        defaults.set(latest.lastPathComponent, forKey: seenKey)

        let alert = NSAlert()
        alert.messageText = "Localhost quit unexpectedly"
        alert.informativeText = """
            A crash report is on this Mac. Sending it helps fix the cause — \
            nothing is sent unless you choose to.
            """
        alert.addButton(withTitle: "Copy Report & Email")
        alert.addButton(withTitle: "Show Report")
        alert.addButton(withTitle: "Ignore")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let report = try? String(contentsOf: latest, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
            contactSupport(subject: "Localhost crash report")
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([latest])
        default:
            break
        }
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func present(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
