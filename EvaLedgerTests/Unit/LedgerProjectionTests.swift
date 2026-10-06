//
//  LedgerProjectionTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

struct LedgerProjectionTests {

    @Test func projectionOrderingUnresolvedAttemptsFirstThenTransactionsByFirstSeenOrder() {
        var state = LedgerState()

        // Two transactions merged in order
        let tx1 = Transaction(id: "tx_first", fromUsername: "eva", toUsername: "alex", amountCents: 1000, description: "first", status: .completed)
        let tx2 = Transaction(id: "tx_second", fromUsername: "eva", toUsername: "alex", amountCents: 2000, description: "second", status: .completed)
        state.merge(feedPage: FeedResponse(transactions: [tx1, tx2], cursor: 1, balanceCents: 97000))

        // Two attempts with different timestamps
        let olderDate = Date(timeIntervalSince1970: 1000)
        let newerDate = Date(timeIntervalSince1970: 2000)

        let attemptOld = PaymentAttempt(id: UUID(), idempotencyKey: "k_old", toUsername: "mila", amountCents: 500, description: "older attempt", createdAt: olderDate, state: .unconfirmed)
        let attemptNew = PaymentAttempt(id: UUID(), idempotencyKey: "k_new", toUsername: "noor", amountCents: 600, description: "newer attempt", createdAt: newerDate, state: .sending)

        state.recordAttempt(attemptOld)
        state.recordAttempt(attemptNew)

        let (rows, balance) = LedgerProjection.project(state: state, isStale: false)

        #expect(rows.count == 4)
        // 1. Newest attempt first
        #expect(rows[0].description == "newer attempt")
        #expect(rows[0].status == .sending)

        // 2. Older attempt second
        #expect(rows[1].description == "older attempt")
        #expect(rows[1].status == .unconfirmed)

        // 3. Newest transaction by firstSeenOrder third (tx_second)
        #expect(rows[2].description == "second")
        #expect(rows[2].status == .completed)

        // 4. Oldest transaction fourth (tx_first)
        #expect(rows[3].description == "first")
        #expect(rows[3].status == .completed)

        #expect(balance.formattedAmount == "970.00")
        #expect(balance.isStale == false)
    }

    @Test func projectionSignAndCounterparty() {
        var state = LedgerState()

        // Outgoing transaction from Eva
        let outgoingTx = Transaction(id: "tx_out", fromUsername: "eva", toUsername: "alex", amountCents: 2500, description: "lunch", status: .completed)
        // Incoming transaction to Eva
        let incomingTx = Transaction(id: "tx_in", fromUsername: "mila", toUsername: "eva", amountCents: 1708, description: "split", status: .pending)

        state.merge(feedPage: FeedResponse(transactions: [outgoingTx, incomingTx], cursor: 1, balanceCents: 99208))

        let (rows, _) = LedgerProjection.project(state: state, isStale: false)

        let outRow = rows.first { $0.id == "tx_out" }!
        #expect(outRow.displayAmountCents == -2500)
        #expect(outRow.counterparty == "alex")

        let inRow = rows.first { $0.id == "tx_in" }!
        #expect(inRow.displayAmountCents == 1708)
        #expect(inRow.counterparty == "mila")
    }

    @Test func projectionNeverContainsTwoRowsForSameTransactionAndAttempt() {
        var state = LedgerState()
        let matchingKey = "shared_idempotency_key"

        // Transaction present in ledger with matching key
        let tx = Transaction(id: "tx_real", fromUsername: "eva", toUsername: "alex", amountCents: 2500, description: "lunch", status: .pending, idempotencyKey: matchingKey)
        state.transactions["tx_real"] = tx
        state.firstSeenOrders["tx_real"] = 0

        // If an attempt with the same idempotency key is somehow still present in attempts array
        let lingeringAttempt = PaymentAttempt(id: UUID(), idempotencyKey: matchingKey, toUsername: "alex", amountCents: 2500, description: "lunch", createdAt: Date(), state: .unconfirmed)
        state.attempts.append(lingeringAttempt)

        let (rows, _) = LedgerProjection.project(state: state, isStale: false)

        // Only the transaction row is projected, NEVER the attempt row
        #expect(rows.count == 1)
        #expect(rows[0].id == "tx_real")
        #expect(rows[0].status == .pending)
    }

    @Test func projectionRowStatusMapping() {
        var state = LedgerState()

        let txRejected = Transaction(id: "tx_rej", fromUsername: "eva", toUsername: "alex", amountCents: 1000, description: "rej", status: .rejected, rejectionReason: "Refused by receiving bank")
        let txUnknown = Transaction(id: "tx_unk", fromUsername: "eva", toUsername: "alex", amountCents: 1000, description: "unk", status: .unknown("in_flight_hold"))

        state.merge(feedPage: FeedResponse(transactions: [txRejected, txUnknown], cursor: 1, balanceCents: 100000))

        let (rows, _) = LedgerProjection.project(state: state, isStale: false)

        let rejRow = rows.first { $0.id == "tx_rej" }!
        #expect(rejRow.status == .rejected(reason: "Refused by receiving bank"))

        let unkRow = rows.first { $0.id == "tx_unk" }!
        #expect(unkRow.status == .unconfirmed) // Unknown bank status is projected as unconfirmed
    }

    @Test func balanceDisplayNeverDerivedFromRowSummation() {
        var state = LedgerState()

        // Multiple transactions whose sum is -10000 cents
        let tx1 = Transaction(id: "tx_1", fromUsername: "eva", toUsername: "alex", amountCents: 10000, description: "big payment", status: .completed)
        state.merge(feedPage: FeedResponse(transactions: [tx1], cursor: 1, balanceCents: 85000))

        // Directly manipulate bankBalanceCents to something completely different from math
        state.bankBalanceCents = 123456

        let (_, balance) = LedgerProjection.project(state: state, isStale: true)
        // Must show verbatim bank balance, not arithmetic
        #expect(balance.formattedAmount == "1,234.56")
        #expect(balance.isStale == true)
    }
}
