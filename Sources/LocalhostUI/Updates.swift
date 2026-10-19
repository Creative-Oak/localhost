import Foundation
import Sparkle

/// Software updates, through Sparkle, from the GitHub releases of this repo.
///
/// Sparkle's own scheduler is switched off (`SUEnableAutomaticChecks` is false
/// in Info.plist) because it runs a timer for as long as the app is running.
/// Instead the check is driven by the panel opening, at most once a day, so the
/// app keeps doing nothing while it is closed. This is the only network
/// request the app makes, and it can be turned off.
@MainActor
public enum Updates {
    private static let automaticKey = "checksForUpdatesAutomatically"
    private static let interval: TimeInterval = 24 * 60 * 60

    /// Started lazily: the headless renderer and `--list` never touch it.
    private static let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    /// A bundle without a feed URL is a debug build from `swift run`, where
    /// Sparkle would only report a configuration error.
    private static var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    public static var checksAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: automaticKey) }
    }

    public static func checkForUpdates() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }

    /// Called when the panel opens. Silent unless there is an update.
    public static func checkIfDue() {
        guard isConfigured, checksAutomatically else { return }
        let updater = controller.updater
        if let last = updater.lastUpdateCheckDate, Date().timeIntervalSince(last) < interval {
            return
        }
        updater.checkForUpdatesInBackground()
    }
}
