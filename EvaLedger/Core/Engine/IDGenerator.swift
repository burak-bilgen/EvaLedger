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
