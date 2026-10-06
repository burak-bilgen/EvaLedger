//
//  MoneyTests.swift
//  EvaLedgerTests
//

import Testing
@testable import EvaLedger

struct MoneyTests {

    @Test func formattingStandardCents() {
        #expect(Money.format(cents: 100000) == "1,000.00")
        #expect(Money.format(cents: 1708) == "17.08")
        #expect(Money.format(cents: 5) == "0.05")
        #expect(Money.format(cents: 0) == "0.00")
        #expect(Money.format(cents: 100) == "1.00")
        #expect(Money.format(cents: 123456789) == "1,234,567.89")
    }

    @Test func formattingNegativeCents() {
        #expect(Money.format(cents: -2500) == "-25.00")
        #expect(Money.format(cents: -5) == "-0.05")
        #expect(Money.format(cents: -100000) == "-1,000.00")
    }

    @Test func parsingValidInputs() throws {
        #expect(try Money.parse(input: "25") == 2500)
        #expect(try Money.parse(input: "25.5") == 2550)
        #expect(try Money.parse(input: "25.50") == 2550)
        #expect(try Money.parse(input: "25,50") == 2550)
        #expect(try Money.parse(input: "25,5") == 2550)
        #expect(try Money.parse(input: "0.05") == 5)
        #expect(try Money.parse(input: "0,05") == 5)
        #expect(try Money.parse(input: "1000") == 100000)
        #expect(try Money.parse(input: "  25.50  ") == 2550)
    }

    @Test func parsingRejections() {
        // Empty / whitespace
        #expect(throws: MoneyParseError.empty) {
            try Money.parse(input: "")
        }
        #expect(throws: MoneyParseError.empty) {
            try Money.parse(input: "   ")
        }

        // Negative
        #expect(throws: MoneyParseError.negative) {
            try Money.parse(input: "-25")
        }
        #expect(throws: MoneyParseError.negative) {
            try Money.parse(input: "-0.50")
        }

        // Zero
        #expect(throws: MoneyParseError.zero) {
            try Money.parse(input: "0")
        }
        #expect(throws: MoneyParseError.zero) {
            try Money.parse(input: "0.00")
        }
        #expect(throws: MoneyParseError.zero) {
            try Money.parse(input: "0,0")
        }

        // More than two decimals
        #expect(throws: MoneyParseError.moreThanTwoDecimals) {
            try Money.parse(input: "25.123")
        }
        #expect(throws: MoneyParseError.moreThanTwoDecimals) {
            try Money.parse(input: "0.001")
        }

        // Non numeric
        #expect(throws: MoneyParseError.nonNumeric) {
            try Money.parse(input: "abc")
        }
        #expect(throws: MoneyParseError.nonNumeric) {
            try Money.parse(input: "25.5.5")
        }
        #expect(throws: MoneyParseError.nonNumeric) {
            try Money.parse(input: "25a")
        }
        #expect(throws: MoneyParseError.nonNumeric) {
            try Money.parse(input: "$25")
        }

        // Overflow
        #expect(throws: MoneyParseError.overflow) {
            try Money.parse(input: "999999999999999999999999999999")
        }
    }
}
