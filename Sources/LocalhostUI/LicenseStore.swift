import Foundation
import LocalhostKit
import Observation

/// Holds the licence key and the trial clock.
///
/// Both live in `UserDefaults`, which a determined person can reset. That is a
/// deliberate limit: hiding the trial date in the keychain or a stray file
/// buys a few minutes against someone who was never going to pay, at the cost
/// of looking like malware to everyone else. The honest defence against
/// copying is a signed key, not a hidden clock.
@MainActor
@Observable
public final class LicenseStore {
    private enum Key {
        static let license = "licenseKey"
        static let firstRun = "firstRunDate"
    }

    private let defaults: UserDefaults
    private let policy = EntitlementPolicy()

    public private(set) var entitlement: Entitlement = .trial(daysRemaining: EntitlementPolicy.trialDays)

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The first launch is what starts the clock, so record it once.
        if defaults.object(forKey: Key.firstRun) == nil {
            defaults.set(Date(), forKey: Key.firstRun)
        }
        refresh()
    }

    public func refresh() {
        entitlement = policy.entitlement(
            licenseKey: defaults.string(forKey: Key.license),
            firstRun: defaults.object(forKey: Key.firstRun) as? Date)
    }

    /// Stores a key only if it verifies, so an invalid paste cannot displace a
    /// working licence.
    @discardableResult
    public func activate(_ key: String) -> Result<License, License.Failure> {
        do {
            let license = try License.verify(key)
            defaults.set(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.license)
            refresh()
            return .success(license)
        } catch let failure as License.Failure {
            return .failure(failure)
        } catch {
            return .failure(.malformed)
        }
    }

    public var statusDescription: String {
        switch entitlement {
        case let .licensed(license): return "Licensed to \(license.email)"
        case let .trial(days): return "Trial — \(days) day\(days == 1 ? "" : "s") left"
        case .expired: return "Trial ended"
        }
    }
}
