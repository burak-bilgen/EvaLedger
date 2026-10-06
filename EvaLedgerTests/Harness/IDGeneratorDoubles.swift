//
//  IDGeneratorDoubles.swift
//  EvaLedgerTests
//

import Foundation
@testable import EvaLedger

public final class DeterministicIDGenerator: IDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var nextAttemptNumber: Int = 1
    private var nextKeyNumber: Int = 1
    private let keyPrefix: String

    public init(prefix: String = "k") {
        self.keyPrefix = prefix
    }

    public func generateAttemptID() -> UUID {
        lock.withLock {
            let num = nextAttemptNumber
            nextAttemptNumber += 1
            let formatted = String(format: "00000000-0000-0000-0000-%012d", num)
            return UUID(uuidString: formatted) ?? UUID()
        }
    }

    public func generateIdempotencyKey() -> String {
        lock.withLock {
            let key = "\(keyPrefix)\(nextKeyNumber)"
            nextKeyNumber += 1
            return key
        }
    }
}
