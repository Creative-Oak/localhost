import AppKit
import Foundation

/// The browser and terminal a row opens in.
///
/// There is no settings window, and deliberately so: choosing an app from the
/// "Open in" submenu is what sets the default. The preference emerges from use
/// rather than from a screen someone has to find, which suits a utility whose
/// whole panel is smaller than most settings dialogs.
struct AppChoice: Hashable, Identifiable, Sendable {
    let name: String
    let url: URL
    var id: URL { url }
}

@MainActor
enum ExternalApps {
    private static let browserKey = "preferredBrowserPath"
    private static let terminalKey = "preferredTerminalPath"

    /// Every app that has registered itself as able to open an http URL.
    static func browsers() -> [AppChoice] {
        guard let probe = URL(string: "http://localhost") else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: probe)
            .map { AppChoice(name: displayName(of: $0), url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// macOS has no notion of a default terminal, so this is a known list
    /// filtered by what is actually installed.
    static func terminals() -> [AppChoice] {
        let identifiers = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty",
            "org.alacritty",
            "co.zeit.hyper",
        ]
        return identifiers
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { AppChoice(name: displayName(of: $0), url: $0) }
    }

    static var preferredBrowser: AppChoice? {
        get { stored(browserKey, among: browsers()) }
        set { store(newValue, at: browserKey) }
    }

    static var preferredTerminal: AppChoice? {
        get { stored(terminalKey, among: terminals()) ?? terminals().first }
        set { store(newValue, at: terminalKey) }
    }

    static func open(_ url: URL, in choice: AppChoice?) {
        guard let choice else {
            NSWorkspace.shared.open(url)          // the system default browser
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: choice.url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openInTerminal(_ folder: URL, using choice: AppChoice?) {
        guard let terminal = choice ?? preferredTerminal else {
            // Nothing recognised is installed; the folder is still useful.
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
            return
        }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal.url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Storage

    private static func stored(_ key: String, among choices: [AppChoice]) -> AppChoice? {
        guard let path = UserDefaults.standard.string(forKey: key) else { return nil }
        // A remembered app that has since been deleted must not strand the row.
        return choices.first { $0.url.path == path }
    }

    private static func store(_ choice: AppChoice?, at key: String) {
        guard let choice else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(choice.url.path, forKey: key)
    }

    private static func displayName(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
