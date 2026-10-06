//
//  Scenario5LateRejectionTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

@Suite("Scenario 5: Late Rejection")
struct Scenario5LateRejectionTests {

    @Test("Scenario 5: Completed payment late-rejected by bank refunds Eva and updates row by id without appending")
    func scenario5LateRejectionFlow() async throws {
        let harness = AppHarness()
        let bank = harness.bank
        guard let engine = harness.engine else {
            Issue.record("Harness engine not initialized")
            return
        }

        // Initial sync
        _ = await engine.sync()
        #expect(bank.balance(of: "eva") == 100000)

        // Step 1: Send 2500 to alex, settlePending, sync
        let sendResult = await engine.send(to: "alex", amountCents: 2500, description: "lunch")
        guard case .accepted(let txn) = sendResult else {
            Issue.record("Expected .accepted but got: \(sendResult)")
            return
        }
        #expect(txn.status == .pending)

        bank.settlePending()
        let postSettleSnapshot = await engine.sync()

        // Assert after step 1: exactly 1 row .completed, balance 97500
        #expect(postSettleSnapshot.rows.count == 1)
        #expect(postSettleSnapshot.rows.first?.status == .completed)
        #expect(postSettleSnapshot.balanceDisplay.formattedAmount == "975.00")
        #expect(!postSettleSnapshot.isStale)
        #expect(bank.transactionCount(from: "eva") == 1)
        #expect(bank.paymentRequestCount == 1)

        // Step 2: bank.lateReject(transactionID: <txId>, reason: "The receiving bank refused it"), Eva is refunded
        let rejectionReason = "The receiving bank refused it"
        bank.lateReject(transactionID: txn.id, reason: rejectionReason)

        // Eva is refunded at the bank: balance is 100000 again
        #expect(bank.balance(of: "eva") == 100000)

        // Step 3: App syncs
        let postRejectionSnapshot = await engine.sync()

        // Assert after step 3: STILL exactly 1 row (updated by id, NOT appended)
        #expect(postRejectionSnapshot.rows.count == 1)
        let row = postRejectionSnapshot.rows.first
        #expect(row?.id == txn.id)
        #expect(row?.status == .rejected(reason: rejectionReason))
        // Displayed balance 100000 taken from bank's balance_cents verbatim (NOT computed by app)
        #expect(postRejectionSnapshot.balanceDisplay.formattedAmount == "1,000.00")
        #expect(!postRejectionSnapshot.isStale)
        #expect(bank.transactionCount(from: "eva") == 1)
        #expect(bank.paymentRequestCount == 1)
    }

    @Test("Projection test: RowStatus.rejected carries reason, and displayed balance is never computed from row summation")
    func projectionRejectedRowStatusAndBalanceIndependentOfRows() {
        let reason = "The receiving bank refused it"
        let tx = Transaction(
            id: "tx_rejected_1",
            fromUsername: "eva",
            toUsername: "alex",
            amountCents: 4500,
            description: "concert ticket",
            status: .rejected,
            rejectionReason: reason,
            idempotencyKey: "k_rej"
        )

        // Create a state where the rows would sum to an arbitrary amount (e.g. -4500 cents),
        // but the bank authoritative balance is set to 88888 cents.
        var state = LedgerState(
            schemaVersion: 1,
            transactions: [tx.id: tx],
            firstSeenOrders: [tx.id: 0],
            nextOrder: 1,
            cursor: 10,
            bankBalanceCents: 88888,
            balanceAsOf: Date(),
            attempts: []
        )

        let projection = LedgerProjection.project(state: state, isStale: false)

        // 1. Row carries rejection status and reason
        #expect(projection.rows.count == 1)
        #expect(projection.rows.first?.status == .rejected(reason: reason))

        // 2. Displayed balance is strictly derived from bankBalanceCents (88888 -> 888.88)
        #expect(projection.balance.formattedAmount == "888.88")

        // 3. Mutate ledger to add extra rows that drastically alter arithmetic sum
        let extraTx = Transaction(
            id: "tx_extra",
            fromUsername: "mila",
            toUsername: "eva",
            amountCents: 99999,
            description: "bonus",
            status: .completed,
            rejectionReason: nil,
            idempotencyKey: nil
        )
        state.transactions[extraTx.id] = extraTx
        state.firstSeenOrders[extraTx.id] = 1

        let mutatedProjection = LedgerProjection.project(state: state, isStale: false)
        #expect(mutatedProjection.rows.count == 2)
        // Bank balance display remains 888.88, proving no row summation is ever performed
        #expect(mutatedProjection.balance.formattedAmount == "888.88")
    }
}
