// Seller-side licence tooling. Never ship the private key.
//
//   swift Scripts/make-license.swift --generate-keys
//   swift Scripts/make-license.swift --sign you@example.com --key <private-base64>
//
// The public key goes into License.signingPublicKey. The private key belongs in
// a password manager, not in this repository — anyone holding it can mint keys.
import CryptoKit
import Foundation

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let arguments = CommandLine.arguments

if arguments.contains("--generate-keys") {
    let privateKey = Curve25519.Signing.PrivateKey()
    print("private (keep secret): \(privateKey.rawRepresentation.base64EncodedString())")
    print("public  (into License.signingPublicKey): \(privateKey.publicKey.rawRepresentation.base64EncodedString())")
    exit(0)
}

guard let emailIndex = arguments.firstIndex(of: "--sign"), emailIndex + 1 < arguments.count,
      let keyIndex = arguments.firstIndex(of: "--key"), keyIndex + 1 < arguments.count,
      let privateKeyData = Data(base64Encoded: arguments[keyIndex + 1]),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
else {
    print("""
    usage:
      swift Scripts/make-license.swift --generate-keys
      swift Scripts/make-license.swift --sign <email> --key <private-base64>
    """)
    exit(1)
}

struct Payload: Codable { let e: String; let i: Int; let p: String }

let payload = Payload(
    e: arguments[emailIndex + 1],
    i: Int(Date().timeIntervalSince1970),
    p: "localhost1")

// Sorted keys, so the same payload always signs to the same bytes.
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let payloadData = try encoder.encode(payload)
let signature = try privateKey.signature(for: payloadData)

print("LOCALHOST-\(base64URL(payloadData)).\(base64URL(signature))")
