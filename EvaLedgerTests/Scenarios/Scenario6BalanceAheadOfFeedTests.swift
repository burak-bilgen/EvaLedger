//
//  Scenario6BalanceAheadOfFeedTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

@Suite("Scenario 6: Balance Ahead of Feed")
struct Scenario6BalanceAheadOfFeedTests {

    @Test("Scenario 6: When incoming payment credits balance ahead of feed, bank balance is shown verbatim and feed catches up")
    func scenario6BalanceAheadOfFeedFlow() async throws {
        let harness = AppHarness()
        let bank = harness.bank
        guard let engine = harness.engine else {
            Issue.record("Harness engine not initialized")
            return
        }

        // Step 1: App syncs, balance 100,000 cents ($1,000.00)
        let initialSnapshot = await engine.sync()
        #expect(initialSnapshot.balanceDisplay.formattedAmount == "1,000.00")
        #expect(initialSnapshot.rows.isEmpty)
        #expect(!initialSnapshot.isStale)

        // Step 2: Hold incoming transactions from the feed, Noor pays Eva 1708 cents
        bank.setHoldIncomingFromFeed(true)
        bank.pay(from: "noor", toEva: "eva", amountCents: 1708, description: "lunch share")

        // Bank balance for Eva is immediately 101708 cents
        #expect(bank.balance(of: "eva") == 101708)

        // Step 3: App syncs: Feed returns no new transactions, but balance_cents is 101708
        let intermediateSnapshot = await engine.sync()

        // Assert after step 3:
        // - 0 rows
        #expect(intermediateSnapshot.rows.isEmpty)
        // - displayed balance 101708 ("1,017.08") verbatim from the bank (never corrected back to 100000)
        #expect(intermediateSnapshot.balanceDisplay.formattedAmount == "1,017.08")
        // - isStale false
        #expect(!intermediateSnapshot.isStale)

        // - cursor persisted consistently
        let intermediatePersisted = try harness.readPersistedState()
        #expect(intermediatePersisted?.bankBalanceCents == 101708)
        let cursorAtStep3 = intermediatePersisted?.cursor

        // - Bank holds exactly 1 transaction involving Eva and 0 payment requests from Eva
        #expect(bank.transactions(involving: "eva").count == 1)
        #expect(bank.paymentRequestCount == 0)

        // Step 4: Bank releases held transactions, app syncs: Feed delivers Noor's payment
        bank.releaseHeldTransactions()
        let postReleaseSnapshot = await engine.sync()

        // Assert at the end:
        // - exactly 1 row (incoming +1708 from noor, status .pending)
        #expect(postReleaseSnapshot.rows.count == 1)
        let noorRow = postReleaseSnapshot.rows.first
        #expect(noorRow?.counterparty == "noor")
        #expect(noorRow?.displayAmountCents == 1708)
        #expect(noorRow?.status == .pending)

        // - balance still 101708 ("1,017.08")
        #expect(postReleaseSnapshot.balanceDisplay.formattedAmount == "1,017.08")
        #expect(!postReleaseSnapshot.isStale)
        #expect(bank.transactions(involving: "eva").count == 1)
        #expect(bank.paymentRequestCount == 0)

        // - cursor advanced past the release (proving sequence re-append worked and cursor logic didn't skip it)
        let finalPersisted = try harness.readPersistedState()
        if let cursor3 = cursorAtStep3, let finalCursor = finalPersisted?.cursor {
            #expect(finalCursor > cursor3)
        } else {
            #expect(finalPersisted?.cursor != nil)
        }

        // - a further sync is completely idempotent (still 1 row, same balance)
        let idempotentSnapshot = await engine.sync()
        #expect(idempotentSnapshot.rows.count == 1)
        #expect(idempotentSnapshot.balanceDisplay.formattedAmount == "1,017.08")
        #expect(!idempotentSnapshot.isStale)
    }
}
