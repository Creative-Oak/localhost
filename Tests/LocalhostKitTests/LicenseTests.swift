import CryptoKit
import Foundation
import Testing
@testable import LocalhostKit

@Suite("Licensing")
struct LicenseTests {
    /// A throwaway keypair, so the tests exercise real signatures rather than
    /// a stub, without the shipping key being anywhere near this repository.
    private static let signer = Curve25519.Signing.PrivateKey()
    private var publicKey: String { Self.signer.publicKey.rawRepresentation.base64EncodedString() }

    private func key(
        email: String = "dev@example.com",
        product: String = License.productIdentifier,
        issued: Date = Date(),
        signedBy signer: Curve25519.Signing.PrivateKey = LicenseTests.signer
    ) throws -> String {
        struct Payload: Codable { let e: String; let i: Int; let p: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(
            Payload(e: email, i: Int(issued.timeIntervalSince1970), p: product))
        let signature = try signer.signature(for: payload)
        return "LOCALHOST-\(payload.base64URLEncoded).\(Data(signature).base64URLEncoded)"
    }

    @Test("accepts a key it signed")
    func acceptsValidKey() throws {
        let license = try License.verify(try key(), publicKey: publicKey)
        #expect(license.email == "dev@example.com")
        #expect(license.product == License.productIdentifier)
    }

    @Test("rejects a key signed by anyone else")
    func rejectsForeignSignature() throws {
        // The whole point: minting keys requires the private key.
        let impostor = Curve25519.Signing.PrivateKey()
        #expect(throws: License.Failure.badSignature) {
            try License.verify(try key(signedBy: impostor), publicKey: publicKey)
        }
    }

    @Test("rejects a tampered payload")
    func rejectsTamperedPayload() throws {
        let original = try key(email: "dev@example.com")
        // Swap the payload for one claiming a different owner, keeping the
        // signature. This is the obvious forgery and it must fail.
        let forgedPayload = try key(email: "someone@else.com").split(separator: ".")[0]
        let signature = original.split(separator: ".")[1]
        #expect(throws: License.Failure.self) {
            try License.verify("\(forgedPayload).\(signature)", publicKey: publicKey)
        }
    }

    @Test("rejects a key for another product")
    func rejectsWrongProduct() throws {
        #expect(throws: License.Failure.wrongProduct) {
            try License.verify(try key(product: "somethingelse"), publicKey: publicKey)
        }
    }

    @Test("rejects nonsense", arguments: ["", "hello", "LOCALHOST-", "LOCALHOST-abc", "LOCALHOST-a.b"])
    func rejectsMalformed(input: String) {
        #expect(throws: License.Failure.self) {
            try License.verify(input, publicKey: publicKey)
        }
    }

    @Test("tolerates whitespace from a copy and paste")
    func toleratesWhitespace() throws {
        let padded = "  \n" + (try key()) + "\n "
        #expect(try License.verify(padded, publicKey: publicKey).email == "dev@example.com")
    }
}

@Suite("Entitlement")
struct EntitlementTests {
    private let policy = EntitlementPolicy()

    @Test("a first run starts the full trial")
    func firstRunStartsTrial() {
        #expect(policy.entitlement(licenseKey: nil, firstRun: nil)
                == .trial(daysRemaining: EntitlementPolicy.trialDays))
    }

    @Test("the trial counts down")
    func trialCountsDown() {
        let start = Date()
        let entitlement = policy.entitlement(
            licenseKey: nil, firstRun: start, now: start.addingTimeInterval(3 * 86_400))
        #expect(entitlement == .trial(daysRemaining: EntitlementPolicy.trialDays - 3))
    }

    @Test("the trial expires")
    func trialExpires() {
        let start = Date()
        let entitlement = policy.entitlement(
            licenseKey: nil,
            firstRun: start,
            now: start.addingTimeInterval(Double(EntitlementPolicy.trialDays + 1) * 86_400))
        #expect(entitlement == .expired)
        #expect(!entitlement.canAct)
    }

    @Test("a clock moved backwards neither extends nor expires the trial")
    func clockGoingBackwardsIsHandled() {
        let start = Date()
        let entitlement = policy.entitlement(
            licenseKey: nil, firstRun: start, now: start.addingTimeInterval(-90 * 86_400))
        #expect(entitlement == .trial(daysRemaining: EntitlementPolicy.trialDays))
    }

    @Test("discovery is never gated, even expired")
    func discoveryIsNeverGated() {
        // A port list that lies to an unlicensed user would be remembered as a
        // bug, not as a nudge.
        #expect(Entitlement.expired.canDiscover)
        #expect(Entitlement.trial(daysRemaining: 1).canDiscover)
    }

    @Test("an invalid key falls back to the trial rather than locking out")
    func invalidKeyFallsBackToTrial() {
        let entitlement = policy.entitlement(licenseKey: "LOCALHOST-nonsense", firstRun: nil)
        #expect(entitlement == .trial(daysRemaining: EntitlementPolicy.trialDays))
    }
}
