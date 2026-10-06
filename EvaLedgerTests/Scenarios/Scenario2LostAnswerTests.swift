//
//  Scenario2LostAnswerTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

@Suite("Scenario 2: Lost Answer")
struct Scenario2LostAnswerTests {

    @Test("Scenario 2: Lost answer produces unconfirmed row without local arithmetic, recovers via feed sync")
    func scenario2LostAnswerRecovery() async throws {
        let harness = AppHarness()
        let bank = harness.bank
        guard let engine = harness.engine else {
            Issue.record("Harness engine not initialized")
            return
        }

        // 1. Setup: fresh bank/app, initial sync
        let initialSnapshot = await engine.sync()
        #expect(initialSnapshot.balanceDisplay.formattedAmount == "1,000.00")
        #expect(bank.balance(of: "eva") == 100000)

        // 2. bank.armLostAnswer(): The bank creates payment, but connection drops -> URLError.networkConnectionLost
        bank.armLostAnswer()
        let sendResult = await engine.send(to: "alex", amountCents: 2500, description: "lunch")

        // Assert sendResult is unconfirmed
        guard case .unconfirmed(let attempt) = sendResult else {
            Issue.record("Expected .unconfirmed outcome on lost answer, got: \(sendResult)")
            return
        }
        #expect(attempt.amountCents == 2500)
        #expect(attempt.toUsername == "alex")

        // Immediately after send returns (BEFORE any recovery):
        let midSnapshot = await engine.currentSnapshot()
        // Exactly 1 row, state .unconfirmed (clearly "not confirmed", never shown as pending/completed)
        #expect(midSnapshot.rows.count == 1)
        #expect(midSnapshot.rows.first?.status == .unconfirmed)
        #expect(midSnapshot.rows.first?.counterparty == "alex")
        #expect(midSnapshot.rows.first?.displayAmountCents == -2500)

        // Attempt persisted with its idempotency key on disk
        let persisted = try harness.readPersistedState()
        #expect(persisted?.attempts.count == 1)
        #expect(persisted?.attempts.first?.state == .unconfirmed)
        #expect(persisted?.attempts.first?.idempotencyKey == attempt.idempotencyKey)

        // Bank holds exactly 1 transaction from eva (the payment HAPPENED)
        #expect(bank.transactionCount(from: "eva") == 1)
        #expect(bank.paymentRequestCount == 1)

        // Displayed balance is still the last known bank balance (do NOT subtract locally)
        #expect(midSnapshot.balanceDisplay.formattedAmount == "1,000.00")

        // 3. Recovery = a normal sync: the feed contains the transaction carrying our idempotency_key
        let recoveredSnapshot = await engine.sync()

        // Still exactly 1 row, now .pending
        #expect(recoveredSnapshot.rows.count == 1)
        #expect(recoveredSnapshot.rows.first?.status == .pending)
        // Attempt resolved by key; state attempts is now empty
        #expect(recoveredSnapshot.state.attempts.isEmpty)
        // Authoritative balance 97500 from the bank
        #expect(recoveredSnapshot.balanceDisplay.formattedAmount == "975.00")
        // Assert the engine sent NO second POST
        #expect(bank.paymentRequestCount == 1)

        // 4. bank.settlePending(); sync -> 1 row .completed, balance 97500, bank holds exactly 1
        bank.settlePending()
        let finalSnapshot = await engine.sync()

        #expect(finalSnapshot.rows.count == 1)
        #expect(finalSnapshot.rows.first?.status == .completed)
        #expect(finalSnapshot.balanceDisplay.formattedAmount == "975.00")
        #expect(!finalSnapshot.isStale)
        #expect(bank.transactionCount(from: "eva") == 1)
        #expect(bank.paymentRequestCount == 1)
    }

    @Test("Recovery sync while bank unreachable keeps attempt .unconfirmed and marks isStale true")
    func recoverySyncWhileBankUnreachableLeavesUnconfirmed() async throws {
        let harness = AppHarness()
        let bank = harness.bank
        guard let engine = harness.engine else {
            Issue.record("Harness engine not initialized")
            return
        }

        // Initial sync
        _ = await engine.sync()

        // Lost answer leaves attempt in .unconfirmed
        bank.armLostAnswer()
        _ = await engine.send(to: "alex", amountCents: 2500, description: "lunch")

        let preSync = await engine.currentSnapshot()
        #expect(preSync.rows.count == 1)
        #expect(preSync.rows.first?.status == .unconfirmed)

        // Arm unreachable: bank feed request fails with URLError.notConnectedToInternet
        bank.armUnreachable()
        let failedSyncSnapshot = await engine.sync()

        // Row stays .unconfirmed, isStale is true, nothing is declared notSent (we simply don't know yet)
        #expect(failedSyncSnapshot.rows.count == 1)
        #expect(failedSyncSnapshot.rows.first?.status == .unconfirmed)
        #expect(failedSyncSnapshot.isStale)

        // Bank becomes reachable again; a later sync resolves it
        bank.disarmUnreachable()
        let resolvedSnapshot = await engine.sync()

        #expect(resolvedSnapshot.rows.count == 1)
        #expect(resolvedSnapshot.rows.first?.status == .pending)
        #expect(!resolvedSnapshot.isStale)
        #expect(resolvedSnapshot.balanceDisplay.formattedAmount == "975.00")
    }

    @Test("In-flight guard: A sync running while send is in-flight does not mark attempt as notSent")
    func syncWhileSendInFlightDoesNotMarkAttemptNotSent() async throws {
        let harness = AppHarness()
        let bank = harness.bank
        guard let engine = harness.engine else {
            Issue.record("Harness engine not initialized")
            return
        }

        // Initial sync
        _ = await engine.sync()

        // Hold the send in-flight at the bank gate
        bank.gateNextPayment()
        let sendTask = Task {
            await engine.send(to: "alex", amountCents: 2500, description: "lunch")
        }

        await bank.waitUntilGateReached()

        // Run sync while the payment is currently in-flight
        let syncSnapshot = await engine.sync()

        // Because the attempt ID is in inFlightAttemptIDs, reconciliation MUST NOT mark it notSent
        #expect(syncSnapshot.rows.count == 1)
        #expect(syncSnapshot.rows.first?.status == .sending)

        // Release the gate to finish the send
        bank.releaseGate()
        _ = await sendTask.value

        let finalSnapshot = await engine.currentSnapshot()
        #expect(finalSnapshot.rows.count == 1)
        #expect(finalSnapshot.rows.first?.status == .pending)
    }
}
