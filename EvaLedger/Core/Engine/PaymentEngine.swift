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
    private var syncTask: Task<LedgerSnapshot, Never>? = nil

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

    /// Sends a payment to the specified counterparty.
    /// Invariant: Write-ahead logging persists the attempt in `.sending` state BEFORE any network request is issued.
    public func send(to toUsername: String, amountCents: Int, description: String) async -> SendResult {
        let cleanRecipient = toUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRecipient.isEmpty else {
            return .validationError("Recipient username cannot be empty.")
        }
        guard amountCents > 0 else {
            return .validationError("Amount must be greater than zero.")
        }

        let attemptID = idGenerator.generateAttemptID()
        let idempotencyKey = idGenerator.generateIdempotencyKey()
        let createdAt = clock.now

        let attempt = PaymentAttempt(
            id: attemptID,
            idempotencyKey: idempotencyKey,
            toUsername: cleanRecipient,
            amountCents: amountCents,
            description: description,
            createdAt: createdAt,
            state: .sending
        )

        // Write-ahead logging: Commit attempt to durable storage BEFORE network I/O
        do {
            try await store.mutate { draft in
                draft.recordAttempt(attempt)
            }
        } catch {
            return .notSent(reason: "Failed to persist payment attempt: \(error.localizedDescription)")
        }

        inFlightAttemptIDs.insert(attemptID)
        defer { inFlightAttemptIDs.remove(attemptID) }

        let paymentRequest = PaymentRequest(
            toUsername: cleanRecipient,
            amountCents: amountCents,
            description: description,
            idempotencyKey: idempotencyKey
        )

        let outcome = await retryPolicy.execute {
            await self.bankClient.createPayment(paymentRequest)
        }

        return await applyPaymentOutcome(outcome, attempt: attempt)
    }

    /// Retries a payment attempt that is in `.notSent` state using the SAME attempt ID and idempotency key.
    public func retry(attemptID: UUID) async -> SendResult {
        let currentState = await store.snapshot()
        guard let attempt = currentState.attempts.first(where: { $0.id == attemptID }) else {
            return .validationError("Payment attempt not found.")
        }
        guard case .notSent = attempt.state else {
            return .validationError("Only payment attempts in notSent state can be retried.")
        }

        var retryingAttempt = attempt
        retryingAttempt.state = .sending

        do {
            try await store.mutate { draft in
                draft.updateAttemptState(id: attemptID, state: .sending)
            }
        } catch {
            return .notSent(reason: "Failed to persist attempt state: \(error.localizedDescription)")
        }

        inFlightAttemptIDs.insert(attemptID)
        defer { inFlightAttemptIDs.remove(attemptID) }

        let paymentRequest = PaymentRequest(
            toUsername: retryingAttempt.toUsername,
            amountCents: retryingAttempt.amountCents,
            description: retryingAttempt.description,
            idempotencyKey: retryingAttempt.idempotencyKey
        )

        let outcome = await retryPolicy.execute {
            await self.bankClient.createPayment(paymentRequest)
        }

        return await applyPaymentOutcome(outcome, attempt: retryingAttempt)
    }

    /// Dismisses a terminal un-retryable or rejected attempt (.notSent or .failed).
    public func dismiss(attemptID: UUID) async throws {
        let currentState = await store.snapshot()
        guard let attempt = currentState.attempts.first(where: { $0.id == attemptID }) else {
            return
        }
        switch attempt.state {
        case .notSent, .failed:
            try await store.mutate { draft in
                draft.removeAttempt(id: attemptID)
            }
        case .sending, .unconfirmed:
            // Dismissal disallowed while sending or unconfirmed
            break
        }
    }

    /// Single-flight sync with the bank feed. Concurrent callers await the same in-flight task.
    @discardableResult
    public func sync() async -> LedgerSnapshot {
        if let existing = syncTask {
            return await existing.value
        }

        let task = Task { [weak self] () -> LedgerSnapshot in
            guard let self else {
                return LedgerSnapshot(state: LedgerState(), isStale: true)
            }
            return await self.performSync()
        }
        self.syncTask = task
        let snapshot = await task.value
        self.syncTask = nil
        return snapshot
    }

    private func performSync() async -> LedgerSnapshot {
        let cursor = await store.snapshot().cursor
        do {
            let feedPage = try await bankClient.fetchFeed(cursor: cursor)
            let receivedAt = clock.now
            let updatedState = try await store.mutate { draft -> LedgerState in
                draft.merge(feedPage: feedPage, receivedAt: receivedAt)
                draft.reconcileUnconfirmed(inFlightIDs: self.inFlightAttemptIDs)
                return draft
            }
            self.isStale = false
            return LedgerSnapshot(state: updatedState, isStale: false)
        } catch {
            self.isStale = true
            let currentState = await store.snapshot()
            return LedgerSnapshot(state: currentState, isStale: true)
        }
    }

    /// Converts persisted `.sending` attempts not in flight to `.unconfirmed` on app launch without hitting the network.
    @discardableResult
    public func recoverOnLaunch() async throws -> LedgerSnapshot {
        let updatedState = try await store.mutate { draft -> LedgerState in
            draft.recoverOrphanedSendingAttempts(inFlightIDs: self.inFlightAttemptIDs)
            return draft
        }
        return LedgerSnapshot(state: updatedState, isStale: self.isStale)
    }

    private func applyPaymentOutcome(_ outcome: PaymentOutcome, attempt: PaymentAttempt) async -> SendResult {
        let attemptID = attempt.id
        switch outcome {
        case .accepted(let transaction, _):
            do {
                try await store.mutate { draft in
                    draft.insertIfAbsent(acceptedTransaction: transaction, receivedAt: self.clock.now)
                }
                return .accepted(transaction)
            } catch {
                return .unconfirmed(attempt)
            }

        case .ambiguous(let reason):
            self.isStale = true
            do {
                try await store.mutate { draft in
                    draft.updateAttemptState(id: attemptID, state: .unconfirmed)
                }
            } catch {}
            var updated = attempt
            updated.state = .unconfirmed
            return .unconfirmed(updated)

        case .definitelyNotSent:
            self.isStale = true
            let reason = "Payment was not received by bank"
            do {
                try await store.mutate { draft in
                    draft.updateAttemptState(id: attemptID, state: .notSent(reason: reason))
                }
            } catch {}
            return .notSent(reason: reason)

        case .rejectedFinal(let code, let message):
            self.isStale = true
            do {
                try await store.mutate { draft in
                    draft.updateAttemptState(id: attemptID, state: .failed(code: code, message: message))
                }
            } catch {}
            return .failed(code: code, message: message)

        case .busy:
            self.isStale = true
            let reason = "Bank busy"
            do {
                try await store.mutate { draft in
                    draft.updateAttemptState(id: attemptID, state: .notSent(reason: reason))
                }
            } catch {}
            return .notSent(reason: reason)
        }
    }
}
