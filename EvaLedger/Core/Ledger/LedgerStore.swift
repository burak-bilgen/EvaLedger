//
//  LedgerStore.swift
//  EvaLedger
//

import Foundation

public actor LedgerStore {
    private let persistence: any Persistence
    private var state: LedgerState
    private var continuations: [UUID: AsyncStream<LedgerState>.Continuation] = [:]

    public init(persistence: any Persistence, initialState: LedgerState? = nil) throws {
        self.persistence = persistence
        if let initial = initialState {
            self.state = initial
        } else if let loaded = try persistence.load() {
            self.state = loaded
        } else {
            self.state = LedgerState()
        }
    }

    public func snapshot() -> LedgerState {
        return state
    }

    /// Mutates the ledger state in-memory and persists atomically to disk.
    /// Rollback Rationale:
    /// Disk is the durable source of truth. If saving fails, we roll back in-memory state
    /// to the pre-mutation snapshot and rethrow the error. This guarantees memory never
    /// runs ahead of what is safely committed to disk.
    public func mutate<T>(_ operation: (inout LedgerState) throws -> T) throws -> T {
        let previousState = state
        var draft = state
        let result: T
        do {
            result = try operation(&draft)
        } catch {
            throw error
        }

        do {
            try persistence.save(draft)
            self.state = draft
            notifyContinuations()
            return result
        } catch {
            // Roll back in-memory state so memory does not outpace disk
            self.state = previousState
            throw error
        }
    }

    /// Updates in-memory state without persisting to disk.
    /// Used when persistence fails during post-payment outcome processing to ensure
    /// the in-memory attempt state transitions from .sending to .unconfirmed.
    public func updateStateInMemoryOnly(_ transform: (inout LedgerState) -> Void) {
        transform(&state)
        notifyContinuations()
    }

    public func snapshots() -> AsyncStream<LedgerState> {
        let id = UUID()
        let initial = state

        return AsyncStream { continuation in
            continuation.yield(initial)
            self.addContinuation(continuation, id: id)

            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    private func addContinuation(_ continuation: AsyncStream<LedgerState>.Continuation, id: UUID) {
        continuations[id] = continuation
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func notifyContinuations() {
        let current = state
        for continuation in continuations.values {
            continuation.yield(current)
        }
    }
}
