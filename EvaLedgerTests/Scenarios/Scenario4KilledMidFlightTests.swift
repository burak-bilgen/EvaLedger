//
//  Scenario4KilledMidFlightTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

@Suite("Scenario 4: Killed Mid-Flight")
struct Scenario4KilledMidFlightTests {

    @Test("Test A: Killed before request reaches bank -> recovers unconfirmed -> sync marks notSent -> user retry with same key succeeds")
    func testAKilledBeforeRequestReachesBank() async throws {
        let harness = AppHarness()
        let bank = harness.bank
        guard let engine = harness.engine else {
            Issue.record("Harness engine not initialized")
            return
        }

        // Setup: App has not made any requests yet (paymentRequestCount == 0)
        #expect(bank.paymentRequestCount == 0)

        // Bank hangs the next payment before processing
        bank.hangNextPaymentBeforeBank()

        let sendTask = Task {
            await engine.send(to: "alex", amountCents: 2500, description: "lunch")
        }

        // Wait until request reaches the hanging point
        await bank.waitUntilHangReached()

        // ASSERT: Write-ahead logging - The persisted disk state already contains the attempt (.sending)
        let freshPersistence = FileLedgerPersistence(fileURL: harness.storageURL)
        let diskStateBeforeKill = try freshPersistence.load()
        #expect(diskStateBeforeKill?.attempts.count == 1)
        #expect(diskStateBeforeKill?.attempts.first?.state == .sending)
        let originalKey = diskStateBeforeKill?.attempts.first?.idempotencyKey
        let attemptID = diskStateBeforeKill?.attempts.first?.id
        #expect(originalKey != nil)
        #expect(attemptID != nil)

        // Bank has NOT processed any payment yet
        #expect(bank.transactionCount(from: "eva") == 0)
        #expect(bank.paymentRequestCount == 0)

        // Kill the app process immediately
        harness.kill()
        sendTask.cancel()
        bank.resumeHanging()

        // Relaunch the app from disk against the same FakeBank
        let relaunchedEngine = try await harness.relaunch()

        // ASSERT: Recovered attempt is .unconfirmed (not .sending, not lost)
        let launchSnapshot = await relaunchedEngine.currentSnapshot()
        #expect(launchSnapshot.rows.count == 1)
        #expect(launchSnapshot.rows.first?.status == .unconfirmed)
        // 1 row visible immediately from disk even though the bank is not consulted yet
        #expect(launchSnapshot.rows.first?.counterparty == "alex")
        // NO POST was issued by relaunch
        #expect(bank.paymentRequestCount == 0)

        // Bank settle pending (nothing to settle) and app syncs
        bank.settlePending()
        let syncSnapshot = await relaunchedEngine.sync()

        // ASSERT: Bank holds 0 transactions from Eva
        #expect(bank.transactionCount(from: "eva") == 0)
        // Attempt is now .notSent with a clear reason
        #expect(syncSnapshot.rows.count == 1)
        guard case .notSent(let reason) = syncSnapshot.rows.first?.status else {
            Issue.record("Expected row status .notSent, got: \(String(describing: syncSnapshot.rows.first?.status))")
            return
        }
        #expect(reason == "The bank has no record of this payment. It is safe to try again.")
        // Displayed balance is 100,000 cents (bank's)
        #expect(syncSnapshot.balanceDisplay.formattedAmount == "1,000.00")
        // The app did NOT auto-send: paymentRequestCount == 0
        #expect(bank.paymentRequestCount == 0)

        // User retry of the .notSent attempt: Reuses the SAME attempt and SAME idempotency key
        guard let attemptUUID = attemptID else {
            Issue.record("Missing attempt ID")
            return
        }

        let retryResult = await relaunchedEngine.retry(attemptID: attemptUUID)
        guard case .accepted(let retriedTxn) = retryResult else {
            Issue.record("Expected .accepted outcome from retry, got: \(retryResult)")
            return
        }
        #expect(retriedTxn.idempotencyKey == originalKey)
        #expect(bank.paymentRequestCount == 1)

        // Settle + sync: pending -> completed, bank holds exactly 1
        bank.settlePending()
        let finalSnapshot = await relaunchedEngine.sync()

        #expect(finalSnapshot.rows.count == 1)
        #expect(finalSnapshot.rows.first?.status == .completed)
        #expect(finalSnapshot.balanceDisplay.formattedAmount == "975.00")
        #expect(bank.transactionCount(from: "eva") == 1)
    }

    @Test("Test B: Lost answer + killed before app can react -> recovers unconfirmed -> feed resolves pending -> settled")
    func testBLostAnswerAndKilledBeforeAppReacts() async throws {
        let harness = AppHarness()
        let bank = harness.bank
        guard let engine = harness.engine else {
            Issue.record("Harness engine not initialized")
            return
        }

        // Initial sync
        _ = await engine.sync()
        #expect(bank.paymentRequestCount == 0)

        bank.armLostAnswer()

        // Hook: freeze persistence the instant the bank creates the payment
        // so NOTHING the old engine does after the connection error reaches disk
        bank.setOnPaymentCreatedHook {
            harness.frozenPersistence.freeze()
        }

        // Send payment: bank creates payment, app encounters URLError.networkConnectionLost
        _ = await engine.send(to: "alex", amountCents: 2500, description: "lunch")

        // Kill old objects
        harness.kill()

        // Relaunch app from disk
        let relaunchedEngine = try await harness.relaunch()

        // ASSERT: Attempt was recovered from disk as .unconfirmed
        let launchSnapshot = await relaunchedEngine.currentSnapshot()
        #expect(launchSnapshot.rows.count == 1)
        #expect(launchSnapshot.rows.first?.status == .unconfirmed)
        #expect(bank.paymentRequestCount == 1)

        // Sync: the feed contains the transaction with our idempotency key -> attempt resolves
        let syncSnapshot = await relaunchedEngine.sync()
        #expect(syncSnapshot.rows.count == 1)
        #expect(syncSnapshot.rows.first?.status == .pending)
        #expect(syncSnapshot.state.attempts.isEmpty)
        #expect(syncSnapshot.balanceDisplay.formattedAmount == "975.00")
        #expect(bank.transactionCount(from: "eva") == 1)
        // Assert the app never re-POSTed
        #expect(bank.paymentRequestCount == 1)

        // Settle pending and sync
        bank.settlePending()
        let finalSnapshot = await relaunchedEngine.sync()

        #expect(finalSnapshot.rows.count == 1)
        #expect(finalSnapshot.rows.first?.status == .completed)
        #expect(finalSnapshot.balanceDisplay.formattedAmount == "975.00")
        #expect(bank.transactionCount(from: "eva") == 1)
        #expect(bank.paymentRequestCount == 1)
    }

    @Test("Test C: Killed immediately after 201 before response is persisted to disk -> recovers unconfirmed -> feed resolves")
    func testCKilledImmediatelyAfter201BeforeResponseProcessed() async throws {
        let harness = AppHarness()
        let bank = harness.bank
        guard let engine = harness.engine else {
            Issue.record("Harness engine not initialized")
            return
        }

        // Initial sync
        _ = await engine.sync()

        // Normal successful payment (201 Created from bank), but freeze persistence when bank creates it
        bank.setOnPaymentCreatedHook {
            harness.frozenPersistence.freeze()
        }

        _ = await engine.send(to: "alex", amountCents: 2500, description: "lunch")

        // Kill process immediately
        harness.kill()

        // Relaunch app from disk
        let relaunchedEngine = try await harness.relaunch()

        // Recovered attempt is .unconfirmed
        let launchSnapshot = await relaunchedEngine.currentSnapshot()
        #expect(launchSnapshot.rows.count == 1)
        #expect(launchSnapshot.rows.first?.status == .unconfirmed)
        #expect(bank.paymentRequestCount == 1)

        // Sync resolves it via feed
        let syncSnapshot = await relaunchedEngine.sync()
        #expect(syncSnapshot.rows.count == 1)
        #expect(syncSnapshot.rows.first?.status == .pending)
        #expect(syncSnapshot.state.attempts.isEmpty)
        #expect(syncSnapshot.balanceDisplay.formattedAmount == "975.00")
        #expect(bank.transactionCount(from: "eva") == 1)
        #expect(bank.paymentRequestCount == 1)

        // Settle pending and sync
        bank.settlePending()
        let finalSnapshot = await relaunchedEngine.sync()

        #expect(finalSnapshot.rows.count == 1)
        #expect(finalSnapshot.rows.first?.status == .completed)
        #expect(finalSnapshot.balanceDisplay.formattedAmount == "975.00")
        #expect(bank.transactionCount(from: "eva") == 1)
        #expect(bank.paymentRequestCount == 1)
    }
}
