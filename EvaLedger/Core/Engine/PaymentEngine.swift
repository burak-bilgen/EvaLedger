//
//  PaymentEngine.swift
//  EvaLedger
//

import Foundation

nonisolated public enum SendResult: Equatable, Sendable {
    case accepted(Transaction)
    case unconfirmed(PaymentAttempt)
    case notSent(reason: String)
    case failed(code: String, message: String)
    case validationError(String)
}

nonisolated public struct LedgerSnapshot: Equatable, Sendable {
    public let state: LedgerState
    public let rows: [TransactionRow]
    public let balanceDisplay: BalanceDisplay
    public let isStale: Bool

    public init(state: LedgerState, isStale: Bool) {
        self.state = state
        let projection = LedgerProjection.project(state: state, isStale: isStale)
        self.rows = projection.rows
        self.balanceDisplay = projection.balance
        self.isStale = isStale
    }
}

public actor PaymentEngine {
    public let store: LedgerStore
    public let bankClient: any BankClient
    public let retryPolicy: BusyRetryPolicy
    public let idGenerator: any IDGenerator
    public let clock: any EngineClock

    public private(set) var isStale: Bool = true
    public private(set) var inFlightAttemptIDs: Set<UUID> = []

    public init(
        store: LedgerStore,
        bankClient: any BankClient,
        retryPolicy: BusyRetryPolicy = BusyRetryPolicy(),
        idGenerator: any IDGenerator = SystemIDGenerator(),
        clock: any EngineClock = SystemClock()
    ) {
        self.store = store
        self.bankClient = bankClient
        self.retryPolicy = retryPolicy
        self.idGenerator = idGenerator
        self.clock = clock
    }

    public func currentSnapshot() async -> LedgerSnapshot {
        let state = await store.snapshot()
        return LedgerSnapshot(state: state, isStale: isStale)
    }

    public func send(to toUsername: String, amountCents: Int, description: String) async -> SendResult {
        // Stub for test-first
        return .notSent(reason: "Stub not implemented")
    }

    public func retry(attemptID: UUID) async -> SendResult {
        return .notSent(reason: "Stub not implemented")
    }

    public func dismiss(attemptID: UUID) async throws {}

    @discardableResult
    public func sync() async -> LedgerSnapshot {
        // Stub for test-first
        return await currentSnapshot()
    }

    @discardableResult
    public func recoverOnLaunch() async throws -> LedgerSnapshot {
        return await currentSnapshot()
    }
}
