//
//  Scenario3RepeatedEntriesTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

@Suite("Scenario 3: Repeated Entries")
struct Scenario3RepeatedEntriesTests {

    @Test("Scenario 3 full deduplication: duplicateWithinPage, resendPreviouslyDelivered, and settlement")
    func scenario3RepeatedEntriesDeduplicationAndStateFlow() async throws {
        let harness = AppHarness()
        let bank = harness.bank
        guard let engine = harness.engine else {
            Issue.record("Harness engine not initialized")
            return
        }

        // Step 1: Initial sync (balance 100,000 cents), send 2500 to alex (pending), Mila pays Eva 1000
        _ = await engine.sync()

        let sendResult = await engine.send(to: "alex", amountCents: 2500, description: "lunch")
        guard case .accepted(let txn) = sendResult else {
            Issue.record("Expected .accepted but got: \(sendResult)")
            return
        }
        #expect(txn.status == .pending)

        bank.pay(from: "mila", toEva: "eva", amountCents: 1000, description: "coffee")

        // Step 2: bank.armRepeatedEntries(.duplicateWithinPage); app syncs: page contains both transactions twice
        bank.armRepeatedEntries(.duplicateWithinPage)
        let sync2 = await engine.sync()

        // Assert after sync 2: exactly 2 rows (never 4), correct counterparties and amounts, pending/pending
        #expect(sync2.rows.count == 2)
        let alexRow2 = sync2.rows.first(where: { $0.counterparty == "alex" })
        let milaRow2 = sync2.rows.first(where: { $0.counterparty == "mila" })
        #expect(alexRow2?.displayAmountCents == -2500)
        #expect(alexRow2?.status == .pending)
        #expect(milaRow2?.displayAmountCents == 1000)
        #expect(milaRow2?.status == .pending)

        // Attempt row is NOT duplicated next to transaction row
        #expect(sync2.state.attempts.isEmpty)
        // Displayed balance equals bank balance_cents verbatim: 100000 - 2500 + 1000 = 98500 ("985.00")
        #expect(sync2.balanceDisplay.formattedAmount == "985.00")
        #expect(bank.transactionCount(from: "eva") == 1)
        #expect(bank.paymentRequestCount == 1)

        // Step 3: bank.armRepeatedEntries(.resendPreviouslyDelivered); app syncs
        bank.armRepeatedEntries(.resendPreviouslyDelivered)
        let sync3 = await engine.sync()

        // Assert after sync 3: still exactly 2 rows, pending/pending
        #expect(sync3.rows.count == 2)
        let alexRow3 = sync3.rows.first(where: { $0.counterparty == "alex" })
        let milaRow3 = sync3.rows.first(where: { $0.counterparty == "mila" })
        #expect(alexRow3?.status == .pending)
        #expect(milaRow3?.status == .pending)
        #expect(sync3.state.attempts.isEmpty)
        #expect(sync3.balanceDisplay.formattedAmount == "985.00")
        #expect(bank.transactionCount(from: "eva") == 1)
        #expect(bank.paymentRequestCount == 1)

        // Step 4: bank.settlePending(); app syncs
        bank.settlePending()
        let sync4 = await engine.sync()

        // Assert after sync 4: exactly 2 rows, completed/completed
        #expect(sync4.rows.count == 2)
        let alexRow4 = sync4.rows.first(where: { $0.counterparty == "alex" })
        let milaRow4 = sync4.rows.first(where: { $0.counterparty == "mila" })
        #expect(alexRow4?.status == .completed)
        #expect(milaRow4?.status == .completed)
        #expect(sync4.state.attempts.isEmpty)
        #expect(sync4.balanceDisplay.formattedAmount == "985.00")
        #expect(bank.transactionCount(from: "eva") == 1)
        #expect(bank.paymentRequestCount == 1)
    }

    @Test("Pure unit test: Within a single page, duplicate IDs keep the last occurrence")
    func pureDeduplicationAndLastOccurrenceSemantics() {
        var state = LedgerState()

        // Transaction t1 appears twice in same feed response: first pending, then completed
        let t1Pending = Transaction(
            id: "tx_1",
            fromUsername: "eva",
            toUsername: "alex",
            amountCents: 2000,
            description: "dinner",
            status: .pending,
            rejectionReason: nil,
            idempotencyKey: "k1"
        )
        let t1Completed = Transaction(
            id: "tx_1",
            fromUsername: "eva",
            toUsername: "alex",
            amountCents: 2000,
            description: "dinner",
            status: .completed,
            rejectionReason: nil,
            idempotencyKey: "k1"
        )

        let feed = FeedResponse(
            transactions: [t1Pending, t1Completed],
            cursor: 5,
            balanceCents: 98000
        )

        state.merge(feedPage: feed)

        // Must hold exactly 1 transaction, with the last occurrence (.completed) winning
        #expect(state.transactions.count == 1)
        #expect(state.transactions["tx_1"]?.status == .completed)
        #expect(state.cursor == 5)
        #expect(state.bankBalanceCents == 98000)

        // Documented invariant: The bank feed is a stream of status updates where the bank always
        // transmits CURRENT authoritative state. Re-sending the transaction preserves the current state.
        let reSentFeed = FeedResponse(
            transactions: [t1Completed],
            cursor: 5,
            balanceCents: 98000
        )
        state.merge(feedPage: reSentFeed)
        #expect(state.transactions.count == 1)
        #expect(state.transactions["tx_1"]?.status == .completed)
    }
}
