//
//  Money.swift
//  EvaLedger
//

import Foundation

nonisolated public enum MoneyParseError: Error, Equatable, Sendable, LocalizedError {
    case empty
    case nonNumeric
    case negative
    case zero
    case moreThanTwoDecimals
    case overflow

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Please enter an amount."
        case .nonNumeric:
            return "Amount must contain only digits and an optional decimal separator."
        case .negative:
            return "Amount cannot be negative."
        case .zero:
            return "Amount must be greater than zero."
        case .moreThanTwoDecimals:
            return "Amount cannot have more than 2 decimal places."
        case .overflow:
            return "Amount is too large."
        }
    }
}

nonisolated public enum Money {
    /// Formats integer cents into a user-friendly string (e.g. 100000 -> "1,000.00", 1708 -> "17.08", 5 -> "0.05", -2500 -> "-25.00").
    /// Uses integer arithmetic only; never uses Double or Float.
    public static func format(cents: Int) -> String {
        let isNegative = cents < 0
        let absCents: UInt64
        if cents == Int.min {
            // Handle Int.min overflow safely
            absCents = UInt64(Int.max) + 1
        } else {
            absCents = UInt64(abs(cents))
        }

        let units = absCents / 100
        let remainder = absCents % 100

        let unitsString = formatUnitsWithGrouping(units)
        let centsString = String(format: "%02llu", remainder)

        let prefix = isNegative ? "-" : ""
        return "\(prefix)\(unitsString).\(centsString)"
    }

    /// Parses user-entered decimal string into integer cents.
    /// Supports "25", "25.5", "25.50", "25,50".
    /// Rejects empty, zero, negative, >2 decimals, non-numeric, overflow.
    public static func parse(input: String) throws(MoneyParseError) -> Int {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw .empty
        }

        if trimmed.hasPrefix("-") {
            throw .negative
        }

        // Check for disallowed characters: only digits and '.' or ',' allowed
        let allowedSeparators: Set<Character> = [".", ","]
        var separatorCount = 0
        for char in trimmed {
            if allowedSeparators.contains(char) {
                separatorCount += 1
                if separatorCount > 1 {
                    throw .nonNumeric
                }
            } else if !char.isNumber {
                throw .nonNumeric
            }
        }

        let parts = trimmed.split(whereSeparator: { $0 == "." || $0 == "," })
        if parts.isEmpty {
            throw .empty
        }

        let unitsPartString: String
        let decimalsPartString: String

        if separatorCount == 0 {
            unitsPartString = String(parts[0])
            decimalsPartString = ""
        } else {
            // Check if input was just "." or ","
            if parts.count == 1 {
                if trimmed.hasPrefix(".") || trimmed.hasPrefix(",") {
                    unitsPartString = "0"
                    decimalsPartString = String(parts[0])
                } else {
                    unitsPartString = String(parts[0])
                    decimalsPartString = ""
                }
            } else if parts.count == 2 {
                unitsPartString = String(parts[0])
                decimalsPartString = String(parts[1])
            } else {
                throw .nonNumeric
            }
        }

        if decimalsPartString.count > 2 {
            throw .moreThanTwoDecimals
        }

        guard let units = Int(unitsPartString) else {
            throw .overflow
        }

        let centsFraction: Int
        if decimalsPartString.isEmpty {
            centsFraction = 0
        } else if decimalsPartString.count == 1 {
            guard let digit = Int(decimalsPartString) else {
                throw .nonNumeric
            }
            centsFraction = digit * 10
        } else {
            guard let twoDigits = Int(decimalsPartString) else {
                throw .nonNumeric
            }
            centsFraction = twoDigits
        }

        // Check overflow for units * 100 + centsFraction
        if units > (Int.max - centsFraction) / 100 {
            throw .overflow
        }

        let totalCents = units * 100 + centsFraction
        if totalCents <= 0 {
            throw .zero
        }

        return totalCents
    }

    private static func formatUnitsWithGrouping(_ units: UInt64) -> String {
        let str = String(units)
        if str.count <= 3 {
            return str
        }

        var result = ""
        var count = 0
        for char in str.reversed() {
            if count > 0 && count % 3 == 0 {
                result.append(",")
            }
            result.append(char)
            count += 1
        }
        return String(result.reversed())
    }
}
