//
//  LedgerState.swift
//  EvaLedger
//

import Foundation

nonisolated public struct LedgerState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var transactions: [String: Transaction]
    public var firstSeenOrders: [String: Int]
    public var nextOrder: Int
    public var cursor: Int?
    public var bankBalanceCents: Int?
    public var balanceAsOf: Date?
    public var attempts: [PaymentAttempt]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        transactions: [String: Transaction] = [:],
        firstSeenOrders: [String: Int] = [:],
        nextOrder: Int = 0,
        cursor: Int? = nil,
        bankBalanceCents: Int? = nil,
        balanceAsOf: Date? = nil,
        attempts: [PaymentAttempt] = []
    ) {
        self.schemaVersion = schemaVersion
        self.transactions = transactions
        self.firstSeenOrders = firstSeenOrders
        self.nextOrder = nextOrder
        self.cursor = cursor
        self.bankBalanceCents = bankBalanceCents
        self.balanceAsOf = balanceAsOf
        self.attempts = attempts
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case transactions
        case firstSeenOrders = "first_seen_orders"
        case nextOrder = "next_order"
        case cursor
        case bankBalanceCents = "bank_balance_cents"
        case balanceAsOf = "balance_as_of"
        case attempts
    }

    /// Merges a feed page of changes from the bank into the ledger state.
    /// - Upserts by id.
    /// - Within the feed page, the last occurrence of any id wins.
    /// - `firstSeenOrder` is monotonically assigned ONLY to newly discovered transaction IDs.
    /// - `cursor` is updated to max(current, feedPage.cursor) and never regresses.
    /// - `bankBalanceCents` is taken verbatim from the feed response (the bank is authoritative).
    /// - Resolves and removes any attempt whose idempotency key matches a merged transaction.
    public mutating func merge(feedPage: FeedResponse, receivedAt: Date = Date()) {
        for txn in feedPage.transactions {
            if firstSeenOrders[txn.id] == nil {
                firstSeenOrders[txn.id] = nextOrder
                nextOrder += 1
            }
            // Last occurrence wins within the page
            transactions[txn.id] = txn

            // Delete attempt matching idempotency key
            if let key = txn.idempotencyKey, !key.isEmpty {
                attempts.removeAll { $0.idempotencyKey == key }
            }
        }

        if let newCursor = feedPage.cursor {
            if let existing = cursor {
                cursor = max(existing, newCursor)
            } else {
                cursor = newCursor
            }
        }

        bankBalanceCents = feedPage.balanceCents
        balanceAsOf = receivedAt
    }

    /// Upserts returned transaction from POST /v1/payments ONLY IF its id is absent.
    /// Feed copies are always at least as fresh.
    /// Deletes the attempt matching the returned transaction's idempotency key.
    public mutating func insertIfAbsent(acceptedTransaction: Transaction, receivedAt: Date = Date()) {
        if transactions[acceptedTransaction.id] == nil {
            firstSeenOrders[acceptedTransaction.id] = nextOrder
            nextOrder += 1
            transactions[acceptedTransaction.id] = acceptedTransaction
        }

        if let key = acceptedTransaction.idempotencyKey, !key.isEmpty {
            attempts.removeAll { $0.idempotencyKey == key }
        }
    }

    // MARK: - Attempt Helpers

    public mutating func recordAttempt(_ attempt: PaymentAttempt) {
        if let index = attempts.firstIndex(where: { $0.id == attempt.id }) {
            attempts[index] = attempt
        } else {
            attempts.append(attempt)
        }
    }

    public mutating func updateAttemptState(id: UUID, state: AttemptState) {
        if let index = attempts.firstIndex(where: { $0.id == id }) {
            attempts[index].state = state
        }
    }

    public mutating func removeAttempt(id: UUID) {
        attempts.removeAll { $0.id == id }
    }

    /// Reconciles unconfirmed attempts after a successful feed sync.
    /// 1. Drops any attempt matching an already-known transaction key.
    /// 2. Converts any remaining .unconfirmed attempts not currently in flight to .notSent.
    public mutating func reconcileUnconfirmed(inFlightIDs: Set<UUID>) {
        let knownKeys = Set(transactions.values.compactMap { $0.idempotencyKey })
        attempts.removeAll { knownKeys.contains($0.idempotencyKey) }

        for i in 0..<attempts.count {
            if attempts[i].state == .unconfirmed && !inFlightIDs.contains(attempts[i].id) {
                attempts[i].state = .notSent(reason: "The bank has no record of this payment, so it was not sent. It is safe to try again.")
            }
        }
    }

    /// Converts persisted .sending attempts not in flight to .unconfirmed upon process relaunch.
    public mutating func recoverOrphanedSendingAttempts(inFlightIDs: Set<UUID>) {
        for i in 0..<attempts.count {
            if attempts[i].state == .sending && !inFlightIDs.contains(attempts[i].id) {
                attempts[i].state = .unconfirmed
            }
        }
    }
}

