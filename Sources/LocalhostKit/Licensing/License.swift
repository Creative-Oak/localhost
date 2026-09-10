import CryptoKit
import Foundation

/// A licence key, verified on the machine that holds it.
///
/// Keys are signed with Ed25519 by the seller and verified here against a
/// public key compiled into the app. That means **activation never touches the
/// network**: there is no licence server to call, to go down, or to log who is
/// running what. It also means the privacy policy can say the app makes no
/// network requests without an asterisk, which is worth more than the
/// revocation a phone-home would buy.
///
/// The trade is that a leaked key cannot be revoked remotely. For a
/// single-purpose developer utility that is the right side of the trade; the
/// answer to a leaked key is a new signing key in the next release.
public struct License: Hashable, Sendable {
    public let email: String
    public let issued: Date
    /// Which product the key is for, so one signing key can serve several.
    public let product: String

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case malformed
        case badSignature
        case wrongProduct

        public var description: String {
            switch self {
            case .malformed: return "That does not look like a licence key."
            case .badSignature: return "That licence key is not valid."
            case .wrongProduct: return "That licence key is for a different product."
            }
        }
    }

    /// The product identifier this build accepts.
    public static let productIdentifier = "localhost1"

    /// The seller's public key, base64. The matching private key never leaves
    /// the seller and is not in this repository — see Scripts/make-license.swift.
    ///
    /// Replacing this string invalidates every key already issued, which is the
    /// intended remedy if a key is ever published.
    public static let signingPublicKey = "PLACEHOLDER_PUBLIC_KEY_REPLACE_BEFORE_RELEASE"

    // MARK: - Parsing

    private struct Payload: Codable {
        let e: String       // email
        let i: Int          // issued, seconds since epoch
        let p: String       // product
    }

    /// Keys look like `LOCALHOST-<payload>.<signature>`, both base64url.
    /// Long, but they are pasted rather than typed.
    public static func verify(
        _ key: String,
        publicKey: String = License.signingPublicKey,
        product: String = License.productIdentifier
    ) throws -> License {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("LOCALHOST-") else { throw Failure.malformed }

        let body = trimmed.dropFirst("LOCALHOST-".count)
        let halves = body.split(separator: ".", maxSplits: 1)
        guard halves.count == 2,
              let payloadData = Data(base64URLEncoded: String(halves[0])),
              let signature = Data(base64URLEncoded: String(halves[1]))
        else { throw Failure.malformed }

        guard let publicKeyData = Data(base64Encoded: publicKey),
              let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              verifier.isValidSignature(signature, for: payloadData)
        else { throw Failure.badSignature }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: payloadData) else {
            throw Failure.malformed
        }
        guard payload.p == product else { throw Failure.wrongProduct }

        return License(
            email: payload.e,
            issued: Date(timeIntervalSince1970: TimeInterval(payload.i)),
            product: payload.p)
    }
}

extension Data {
    /// base64url, so a key survives being pasted through a URL or an email
    /// client that mangles `+` and `/`.
    init?(base64URLEncoded string: String) {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        self.init(base64Encoded: padded)
    }

    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
