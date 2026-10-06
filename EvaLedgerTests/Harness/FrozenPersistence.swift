//
//  FrozenPersistence.swift
//  EvaLedgerTests
//

import Foundation
@testable import EvaLedger

/// Persistence wrapper that simulates instant process death.
/// Once `freeze()` is called, all subsequent `save(_:)` calls are silently dropped,
/// ensuring nothing from old objects can reach disk after the kill instant.
nonisolated public final class FrozenPersistence: Persistence, @unchecked Sendable {
    private let underlying: any Persistence
    private let lock = NSLock()
    private var isFrozen: Bool = false

    public init(wrapping: any Persistence) {
        self.underlying = wrapping
    }

    public func freeze() {
        lock.lock()
        defer { lock.unlock() }
        isFrozen = true
    }

    public func load() throws -> LedgerState? {
        return try underlying.load()
    }

    public func save(_ state: LedgerState) throws {
        lock.lock()
        let frozen = isFrozen
        lock.unlock()

        if frozen {
            // Silently drop write
            return
        }
        try underlying.save(state)
    }
}
