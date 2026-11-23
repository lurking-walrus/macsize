import Foundation

/// Deterministic byte formatting and parsing (independent of user locale so
/// CLI output is stable and scriptable).
public enum SizeFormatter {
    private static let decimalUnits = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
    private static let binaryUnits = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]

    /// Format `bytes` using decimal (1000, like Finder) or binary (1024) units.
    public static func string(_ bytes: Int64, binary: Bool = false) -> String {
        let base: Double = binary ? 1024 : 1000
        let units = binary ? binaryUnits : decimalUnits
        let negative = bytes < 0
        var value = Double(bytes.magnitude)
        var unit = 0
        while value >= base && unit < units.count - 1 {
            value /= base
            unit += 1
        }
        let sign = negative ? "-" : ""
        if unit == 0 { return "\(sign)\(Int64(value)) B" }
        let digits = value < 10 ? 2 : (value < 100 ? 1 : 0)
        return sign + String(format: "%.\(digits)f", value) + " " + units[unit]
    }

    /// Parse sizes like `500`, `10K`, `1.5MB`, `2GiB`, `3t`.
    /// Suffixes without `i` are decimal; with `i` they are binary.
    public static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty else { return nil }
        let numberPart = trimmed.prefix { $0.isNumber || $0 == "." }
        var suffix = trimmed.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces)
        guard let number = Double(numberPart), number >= 0 else { return nil }

        if suffix.hasSuffix("B") { suffix.removeLast() }
        let binary = suffix.hasSuffix("I")
        if binary { suffix.removeLast() }
        let base: Double = binary ? 1024 : 1000
        let exponents: [String: Double] = ["": 0, "K": 1, "M": 2, "G": 3, "T": 4, "P": 5]
        guard let exponent = exponents[suffix] else { return nil }
        if binary && exponent == 0 { return nil }
        let result = number * pow(base, exponent)
        guard result < Double(Int64.max) else { return nil }
        return Int64(result.rounded())
    }

    /// Group digits with commas, e.g. 1234567 -> "1,234,567".
    public static func grouped(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var out = ""
        for (index, character) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return value < 0 ? "-" + out : out
    }
}
