import Foundation

public enum UpdateError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case missingPublicKey
    case invalidPublicKey
    case invalidSignatureEncoding
    case checksumMismatch(expected: String, actual: String)
    case signatureInvalid
    case invalidURL(String)
    case httpStatus(Int, url: String)
    case directoryNotWritable(String)
    case temporaryDirectoryFailed(String)
    case extractionFailed(String)
    case binaryMissing
    case versionMismatch(expected: String, actual: String?)
    case replaceFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case .missingPublicKey:
            return "This build has no update signing key, so it can't verify downloads. Refusing to self-update."
        case .invalidPublicKey:
            return "The built-in update signing key is malformed. Refusing to self-update."
        case .invalidSignatureEncoding:
            return "The release signature isn't valid base64 Ed25519. Refusing to install."
        case let .checksumMismatch(expected, actual):
            return "Downloaded file's SHA-256 (\(actual)) doesn't match the release manifest (\(expected)). Refusing to install."
        case .signatureInvalid:
            return "Downloaded file's Ed25519 signature is invalid. Refusing to install."
        case let .invalidURL(url):
            return "Invalid download URL in release manifest: \(url)"
        case let .httpStatus(status, url):
            return "Download failed with HTTP \(status): \(url)"
        case let .directoryNotWritable(directory):
            return "Can't write to \(directory). Run `sudo macsize update` to update this install."
        case let .temporaryDirectoryFailed(directory):
            return "Couldn't create a temporary directory in \(directory)."
        case let .extractionFailed(detail):
            return "Couldn't extract the release archive: \(detail)"
        case .binaryMissing:
            return "The release archive doesn't contain a `macsize` binary."
        case let .versionMismatch(expected, actual):
            return "The downloaded binary reports version \(actual ?? "(none)"), expected \(expected). Refusing to install."
        case let .replaceFailed(path, reason):
            return "Couldn't replace \(path): \(reason)"
        }
    }

    public var errorDescription: String? { description }
}
