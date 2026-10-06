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
    private var saveSuccessCount: Int = 0
    private var throwAfterSaves: Int? = nil
    private var saveError: (any Error)? = nil

    public init(wrapping: any Persistence) {
        self.underlying = wrapping
    }

    public func freeze() {
        lock.lock()
        defer { lock.unlock() }
        isFrozen = true
    }

    public func armThrowOnSave(_ error: any Error = PersistenceError.writeFailed(NSError(domain: "disk_full", code: 1))) {
        lock.lock()
        defer { lock.unlock() }
        saveError = error
        throwAfterSaves = 0
    }

    public func armThrowAfterSuccessfulSaves(_ count: Int, error: any Error = PersistenceError.writeFailed(NSError(domain: "disk_full", code: 1))) {
        lock.lock()
        defer { lock.unlock() }
        throwAfterSaves = count
        saveError = error
    }

    public func load() throws -> LedgerState? {
        return try underlying.load()
    }

    public func save(_ state: LedgerState) throws {
        lock.lock()
        let frozen = isFrozen
        let afterCount = throwAfterSaves
        let currentCount = saveSuccessCount
        let errorToThrow = saveError
        if let afterCount, currentCount >= afterCount, let errorToThrow {
            lock.unlock()
            throw errorToThrow
        }
        lock.unlock()

        if frozen {
            // Silently drop write
            return
        }
        try underlying.save(state)

        lock.lock()
        saveSuccessCount += 1
        lock.unlock()
    }
}
