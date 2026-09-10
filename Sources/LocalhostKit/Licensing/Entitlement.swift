import Foundation

/// What the app is currently allowed to do, and why.
///
/// The trial is deliberately not enforced by hiding the product: a port list
/// that lies to an unlicensed user would make the app useless as an emergency
/// tool and would be remembered as a bug rather than a nudge. It stops the
/// *actions* — quitting a process, freeing a port — and keeps discovery
/// working forever.
public enum Entitlement: Hashable, Sendable {
    case licensed(License)
    case trial(daysRemaining: Int)
    case expired

    /// Discovery is never gated. Whatever else is true, the list is true.
    public var canDiscover: Bool { true }

    /// Anything that changes the machine is.
    public var canAct: Bool {
        switch self {
        case .licensed, .trial: return true
        case .expired: return false
        }
    }

    public var isLicensed: Bool {
        if case .licensed = self { return true }
        return false
    }
}

/// Works out the entitlement from a stored key and a first-run date.
///
/// Pure, so the awkward cases — a clock moved backwards, a missing first-run
/// date — are testable without waiting days.
public struct EntitlementPolicy: Sendable {
    public static let trialDays = 14

    public init() {}

    public func entitlement(
        licenseKey: String?,
        firstRun: Date?,
        now: Date = Date()
    ) -> Entitlement {
        if let licenseKey, let license = try? License.verify(licenseKey) {
            return .licensed(license)
        }
        // No record of a first run means this *is* the first run.
        guard let firstRun else { return .trial(daysRemaining: Self.trialDays) }

        let elapsed = now.timeIntervalSince(firstRun)
        // A clock moved backwards must not extend the trial indefinitely, and
        // must not expire it either. Treat it as day zero.
        guard elapsed > 0 else { return .trial(daysRemaining: Self.trialDays) }

        let daysUsed = Int(elapsed / 86_400)
        let remaining = Self.trialDays - daysUsed
        return remaining > 0 ? .trial(daysRemaining: remaining) : .expired
    }
}
