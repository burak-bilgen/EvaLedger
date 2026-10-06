//
//  LedgerStateTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

struct LedgerStateTests {

    @Test func mergeFeedReplacesByIdNoDuplicates() {
        var state = LedgerState()
        let t1 = Transaction(id: "tx_1", fromUsername: "eva", toUsername: "alex", amountCents: 1000, description: "lunch", status: .pending)
        let page1 = FeedResponse(transactions: [t1], cursor: 1, balanceCents: 99000)

        state.merge(feedPage: page1)
        #expect(state.transactions.count == 1)
        #expect(state.transactions["tx_1"]?.status == .pending)
        #expect(state.cursor == 1)
        #expect(state.bankBalanceCents == 99000)

        // Status update for tx_1 in next page
        let t1Updated = Transaction(id: "tx_1", fromUsername: "eva", toUsername: "alex", amountCents: 1000, description: "lunch", status: .completed)
        let page2 = FeedResponse(transactions: [t1Updated], cursor: 2, balanceCents: 99000)

        state.merge(feedPage: page2)
        #expect(state.transactions.count == 1)
        #expect(state.transactions["tx_1"]?.status == .completed)
        #expect(state.firstSeenOrders["tx_1"] == 0) // First seen order must NOT change
        #expect(state.cursor == 2)
    }

    @Test func mergePageWithDuplicateIdsLastOccurrenceWins() {
        var state = LedgerState()
        let t1First = Transaction(id: "tx_dup", fromUsername: "eva", toUsername: "alex", amountCents: 1000, description: "first", status: .pending)
        let t1Second = Transaction(id: "tx_dup", fromUsername: "eva", toUsername: "alex", amountCents: 1000, description: "second", status: .completed)

        let page = FeedResponse(transactions: [t1First, t1Second], cursor: 5, balanceCents: 99000)
        state.merge(feedPage: page)

        #expect(state.transactions.count == 1)
        #expect(state.transactions["tx_dup"]?.description == "second")
        #expect(state.transactions["tx_dup"]?.status == .completed)
    }

    @Test func cursorNeverRegresses() {
        var state = LedgerState(cursor: 10)

        // Feed with smaller cursor
        let pageSmaller = FeedResponse(transactions: [], cursor: 5, balanceCents: 100000)
        state.merge(feedPage: pageSmaller)
        #expect(state.cursor == 10)

        // Feed with larger cursor
        let pageLarger = FeedResponse(transactions: [], cursor: 12, balanceCents: 100000)
        state.merge(feedPage: pageLarger)
        #expect(state.cursor == 12)

        // Feed with nil cursor preserves current
        let pageNil = FeedResponse(transactions: [], cursor: nil, balanceCents: 100000)
        state.merge(feedPage: pageNil)
        #expect(state.cursor == 12)
    }

    @Test func attemptResolvedByIdempotencyKeyOnMerge() {
        var state = LedgerState()
        let attempt = PaymentAttempt(
            id: UUID(),
            idempotencyKey: "key_xyz",
            toUsername: "alex",
            amountCents: 2500,
            description: "dinner",
            createdAt: Date(),
            state: .unconfirmed
        )
        state.recordAttempt(attempt)
        #expect(state.attempts.count == 1)

        let txn = Transaction(
            id: "tx_99",
            fromUsername: "eva",
            toUsername: "alex",
            amountCents: 2500,
            description: "dinner",
            status: .pending,
            idempotencyKey: "key_xyz"
        )
        let page = FeedResponse(transactions: [txn], cursor: 1, balanceCents: 97500)
        state.merge(feedPage: page)

        #expect(state.attempts.isEmpty)
        #expect(state.transactions["tx_99"] != nil)
    }

    @Test func insertIfAbsentPOSTResponseSemantics() {
        var state = LedgerState()
        let attempt = PaymentAttempt(
            id: UUID(),
            idempotencyKey: "post_key",
            toUsername: "mila",
            amountCents: 500,
            description: "tea",
            createdAt: Date(),
            state: .sending
        )
        state.recordAttempt(attempt)

        let txnFromPOST = Transaction(
            id: "tx_post",
            fromUsername: "eva",
            toUsername: "mila",
            amountCents: 500,
            description: "tea",
            status: .pending,
            idempotencyKey: "post_key"
        )

        state.insertIfAbsent(acceptedTransaction: txnFromPOST)
        #expect(state.transactions["tx_post"]?.status == .pending)
        #expect(state.attempts.isEmpty) // Attempt resolved

        // If transaction already in feed with .completed status, insertIfAbsent does NOT overwrite it
        let txnCompleted = Transaction(
            id: "tx_post",
            fromUsername: "eva",
            toUsername: "mila",
            amountCents: 500,
            description: "tea",
            status: .completed,
            idempotencyKey: "post_key"
        )
        state.transactions["tx_post"] = txnCompleted

        // Call insertIfAbsent with stale pending version: must NOT overwrite
        state.insertIfAbsent(acceptedTransaction: txnFromPOST)
        #expect(state.transactions["tx_post"]?.status == .completed)
    }

    @Test func attemptCRUDHelpers() {
        var state = LedgerState()
        let id1 = UUID()
        let attempt = PaymentAttempt(
            id: id1,
            idempotencyKey: "k1",
            toUsername: "noor",
            amountCents: 1500,
            description: "snack",
            createdAt: Date(),
            state: .sending
        )

        state.recordAttempt(attempt)
        #expect(state.attempts.count == 1)

        state.updateAttemptState(id: id1, state: .notSent(reason: "Unreachable"))
        #expect(state.attempts.first?.state == .notSent(reason: "Unreachable"))

        state.removeAttempt(id: id1)
        #expect(state.attempts.isEmpty)
    }

    @Test func reconcileUnconfirmedTransitionsToUserFriendlyNotSent() {
        var state = LedgerState()
        let id1 = UUID()
        let attempt = PaymentAttempt(
            id: id1,
            idempotencyKey: "k1",
            toUsername: "alex",
            amountCents: 1000,
            description: "test",
            createdAt: Date(),
            state: .unconfirmed
        )
        state.recordAttempt(attempt)
        state.reconcileUnconfirmed(inFlightIDs: [])
        #expect(state.attempts.first?.state == .notSent(reason: "The bank has no record of this payment. It is safe to try again."))
    }
}
