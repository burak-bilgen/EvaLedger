//
//  LedgerProjection.swift
//  EvaLedger
//

import Foundation

nonisolated public enum RowStatus: Equatable, Sendable {
    case sending
    case unconfirmed
    case notSent(reason: String)
    case failed(message: String)
    case pending
    case completed
    case rejected(reason: String)
}

nonisolated public struct TransactionRow: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case attempt(UUID)
        case transaction(String)
    }

    public let id: String
    public let source: Source
    public let counterparty: String
    public let displayAmountCents: Int // Outgoing negative, incoming positive
    public let description: String
    public let status: RowStatus
    public let isRetryable: Bool
    public let isDismissible: Bool
    public let createdAt: Date?

    public init(
        id: String,
        source: Source,
        counterparty: String,
        displayAmountCents: Int,
        description: String,
        status: RowStatus,
        isRetryable: Bool,
        isDismissible: Bool,
        createdAt: Date?
    ) {
        self.id = id
        self.source = source
        self.counterparty = counterparty
        self.displayAmountCents = displayAmountCents
        self.description = description
        self.status = status
        self.isRetryable = isRetryable
        self.isDismissible = isDismissible
        self.createdAt = createdAt
    }
}

nonisolated public struct BalanceDisplay: Equatable, Sendable {
    public let formattedAmount: String?
    public let asOf: Date?
    public let isStale: Bool

    public init(formattedAmount: String?, asOf: Date?, isStale: Bool) {
        self.formattedAmount = formattedAmount
        self.asOf = asOf
        self.isStale = isStale
    }
}

nonisolated public enum LedgerProjection {
    /// Pure projection mapping the single source of truth (`LedgerState`) into displayable rows and balance.
    /// Ordering:
    /// 1. Unresolved attempts (newest `createdAt` first).
    /// 2. Merged transactions ordered by `firstSeenOrder` descending.
    /// Deduplication:
    /// - An attempt is never displayed alongside a confirmed transaction sharing the same idempotency key.
    /// Balance:
    /// - Formatted strictly from `state.bankBalanceCents`; NEVER calculated from row summation.
    public static func project(state: LedgerState, isStale: Bool) -> (rows: [TransactionRow], balance: BalanceDisplay) {
        let rows = projectRows(state: state)
        let balance = projectBalance(state: state, isStale: isStale)
        return (rows: rows, balance: balance)
    }

    public static func projectRows(state: LedgerState) -> [TransactionRow] {
        // Collect known idempotency keys from confirmed transactions to guarantee no double rows
        let knownTransactionKeys = Set(state.transactions.values.compactMap { $0.idempotencyKey })

        // 1. Project unresolved attempts
        let filteredAttempts = state.attempts.filter { attempt in
            !knownTransactionKeys.contains(attempt.idempotencyKey)
        }

        let sortedAttempts = filteredAttempts.sorted { a, b in
            a.createdAt > b.createdAt
        }

        let attemptRows: [TransactionRow] = sortedAttempts.map { attempt in
            let rowStatus: RowStatus
            let isRetryable: Bool
            let isDismissible: Bool

            switch attempt.state {
            case .sending:
                rowStatus = .sending
                isRetryable = false
                isDismissible = false
            case .unconfirmed:
                rowStatus = .unconfirmed
                isRetryable = false
                isDismissible = false
            case .notSent(let reason):
                rowStatus = .notSent(reason: reason)
                isRetryable = true
                isDismissible = true
            case .failed(_, let message):
                rowStatus = .failed(message: message)
                isRetryable = false
                isDismissible = true
            }

            return TransactionRow(
                id: attempt.id.uuidString,
                source: .attempt(attempt.id),
                counterparty: attempt.toUsername,
                displayAmountCents: -attempt.amountCents, // Outgoing is always negative
                description: attempt.description,
                status: rowStatus,
                isRetryable: isRetryable,
                isDismissible: isDismissible,
                createdAt: attempt.createdAt
            )
        }

        // 2. Project transactions ordered by firstSeenOrder descending
        let sortedTransactions = state.transactions.values.sorted { t1, t2 in
            let order1 = state.firstSeenOrders[t1.id] ?? 0
            let order2 = state.firstSeenOrders[t2.id] ?? 0
            return order1 > order2
        }

        let transactionRows: [TransactionRow] = sortedTransactions.map { txn in
            let isOutgoing = txn.fromUsername.lowercased() == "eva"
            let counterparty = isOutgoing ? txn.toUsername : txn.fromUsername
            let displayAmount = isOutgoing ? -txn.amountCents : txn.amountCents

            let rowStatus: RowStatus
            switch txn.status {
            case .pending:
                rowStatus = .pending
            case .completed:
                rowStatus = .completed
            case .rejected:
                let reason = txn.rejectionReason ?? "Rejected by bank"
                rowStatus = .rejected(reason: reason)
            case .unknown:
                rowStatus = .unconfirmed
            }

            return TransactionRow(
                id: txn.id,
                source: .transaction(txn.id),
                counterparty: counterparty,
                displayAmountCents: displayAmount,
                description: txn.description,
                status: rowStatus,
                isRetryable: false,
                isDismissible: false,
                createdAt: nil
            )
        }

        return attemptRows + transactionRows
    }

    public static func projectBalance(state: LedgerState, isStale: Bool) -> BalanceDisplay {
        let formatted = state.bankBalanceCents.map { Money.format(cents: $0) }
        return BalanceDisplay(
            formattedAmount: formatted,
            asOf: state.balanceAsOf,
            isStale: isStale
        )
    }
}
