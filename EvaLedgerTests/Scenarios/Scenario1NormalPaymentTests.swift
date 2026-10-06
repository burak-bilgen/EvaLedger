//
//  Scenario1NormalPaymentTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

@Suite("Scenario 1: Normal Payment Flow")
struct Scenario1NormalPaymentTests {

    @Test("Scenario 1 full lifecycle: tap -> in-flight -> confirmed pending -> settled completed")
    func scenario1NormalPaymentFlow() async throws {
        let harness = AppHarness()
        let bank = harness.bank
        guard let engine = harness.engine else {
            Issue.record("Harness engine not initialized")
            return
        }

        // 1. Fresh bank, fresh app, initial sync (balance 100000).
        let initialSnapshot = await engine.sync()
        #expect(initialSnapshot.balanceDisplay.formattedAmount == "1,000.00")
        #expect(initialSnapshot.rows.isEmpty)
        #expect(!initialSnapshot.isStale)
        #expect(bank.balance(of: "eva") == 100000)

        // 2. gateNextPayment(); start send(alex, 2500, "lunch") in a Task; await bank.waitUntilGateReached().
        // ASSERT: exactly 1 row, state .sending (not confirmed), the attempt is on disk,
        // and what the bank holds at this point (document which and assert it).
        bank.gateNextPayment()
        let sendTask = Task {
            await engine.send(to: "alex", amountCents: 2500, description: "lunch")
        }

        await bank.waitUntilGateReached()

        // Mid-flight assertions while held at the bank gate:
        let midFlightSnapshot = await engine.currentSnapshot()
        #expect(midFlightSnapshot.rows.count == 1)
        #expect(midFlightSnapshot.rows.first?.status == .sending)
        #expect(midFlightSnapshot.rows.first?.counterparty == "alex")
        #expect(midFlightSnapshot.rows.first?.displayAmountCents == -2500)

        // Verify the attempt was persisted to disk BEFORE reaching the bank (write-ahead logging)
        let persistedDraft = try harness.readPersistedState()
        #expect(persistedDraft?.attempts.count == 1)
        #expect(persistedDraft?.attempts.first?.state == .sending)

        // What does the bank hold at this point?
        // Documented invariant: The request reached the gate before the bank processed the transaction or deducted funds.
        // Thus, the bank holds exactly 0 transactions from Eva and Eva's balance remains 100,000 cents.
        #expect(bank.transactionCount(from: "eva") == 0)
        #expect(bank.balance(of: "eva") == 100000)

        // 3. releaseGate(); await send.
        // ASSERT: still exactly 1 row, state .pending (attempt row and transaction row are the same row),
        // attempts empty, bank holds exactly 1 transaction from eva.
        bank.releaseGate()
        let sendResult = await sendTask.value
        guard case .accepted(let createdTxn) = sendResult else {
            Issue.record("Expected .accepted result but got: \(sendResult)")
            return
        }
        #expect(createdTxn.status == .pending)
        #expect(createdTxn.amountCents == 2500)

        let postSendSnapshot = await engine.currentSnapshot()
        #expect(postSendSnapshot.rows.count == 1)
        #expect(postSendSnapshot.rows.first?.status == .pending)
        // Verify attempts collection is now empty (attempt atomically deleted upon storing the accepted transaction)
        #expect(postSendSnapshot.state.attempts.isEmpty)
        #expect(bank.transactionCount(from: "eva") == 1)

        // 4. bank.settlePending(); engine.sync().
        // ASSERT: 1 row, .completed, displayed balance 97500, isStale false,
        // bank holds exactly 1 transaction from eva, paymentRequestCount == 1.
        bank.settlePending()
        let finalSnapshot = await engine.sync()

        #expect(finalSnapshot.rows.count == 1)
        #expect(finalSnapshot.rows.first?.status == .completed)
        #expect(finalSnapshot.balanceDisplay.formattedAmount == "975.00")
        #expect(!finalSnapshot.isStale)
        #expect(bank.transactionCount(from: "eva") == 1)
        #expect(bank.paymentRequestCount == 1)
    }
}
