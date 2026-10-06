//
//  IDGenerator.swift
//  EvaLedger
//

import Foundation

nonisolated public protocol IDGenerator: Sendable {
    func generateAttemptID() -> UUID
    func generateIdempotencyKey() -> String
}

nonisolated public struct SystemIDGenerator: IDGenerator {
    public init() {}

    public func generateAttemptID() -> UUID {
        UUID()
    }

    public func generateIdempotencyKey() -> String {
        UUID().uuidString
    }
}

nonisolated public final class DeterministicIDGenerator: IDGenerator, @unchecked Sendable {
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
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", num))!
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
