import CryptoKit
import Foundation

/// Checks downloaded release artifacts against the manifest's SHA-256 and Ed25519 signature.
/// The public key format matches Sparkle's `SUPublicEDKey` (base64 of the raw 32-byte key).
public enum UpdateVerifier {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Throws unless `data` matches `sha256` (hex, case-insensitive) and `signature`
    /// (base64 Ed25519 over the raw bytes) verifies with `publicKey` (base64 raw key).
    public static func verify(_ data: Data, sha256: String, signature: String, publicKey: String?) throws {
        guard let publicKey else { throw UpdateError.missingPublicKey }
        guard let keyData = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { throw UpdateError.invalidPublicKey }

        let actual = sha256Hex(data)
        let expected = sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard actual == expected else { throw UpdateError.checksumMismatch(expected: expected, actual: actual) }

        guard let signatureData = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              signatureData.count == 64
        else { throw UpdateError.invalidSignatureEncoding }
        guard key.isValidSignature(signatureData, for: data) else { throw UpdateError.signatureInvalid }
    }
}
