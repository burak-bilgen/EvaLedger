//
//  IDGeneratorTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

@Suite("IDGenerator Tests")
struct IDGeneratorTests {

    @Test("SystemIDGenerator produces valid UUIDs and unique non-empty idempotency keys")
    func systemIDGeneratorGeneratesValidValues() {
        let generator = SystemIDGenerator()
        let id1 = generator.generateAttemptID()
        let id2 = generator.generateAttemptID()
        #expect(id1 != id2)

        let key1 = generator.generateIdempotencyKey()
        let key2 = generator.generateIdempotencyKey()
        #expect(!key1.isEmpty)
        #expect(!key2.isEmpty)
        #expect(key1 != key2)
    }

    @Test("DeterministicIDGenerator generates sequential keys and valid IDs safely")
    func deterministicIDGeneratorGeneratesSafely() {
        let generator = DeterministicIDGenerator(prefix: "test_k")
        let id1 = generator.generateAttemptID()
        let id2 = generator.generateAttemptID()
        #expect(id1 != id2)

        let key1 = generator.generateIdempotencyKey()
        let key2 = generator.generateIdempotencyKey()
        #expect(key1 == "test_k1")
        #expect(key2 == "test_k2")
    }
}
