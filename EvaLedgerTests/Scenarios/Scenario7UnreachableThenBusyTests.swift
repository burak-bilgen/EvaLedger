//
//  Scenario7UnreachableThenBusyTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

@Suite("Scenario 7: Unreachable, Then Busy")
struct Scenario7UnreachableThenBusyTests {

    @Test("Scenario 7: Unreachable marks notSent, plain sync does NOT auto-send, user retry survives busy and settles")
    func scenario7UnreachableThenBusyWithUserRetryFlow() async throws {
        let harness = AppHarness()
        let bank = harness.bank
        guard let engine = harness.engine else {
            Issue.record("Harness engine not initialized")
            return
        }

        // Step 1: Initial sync, balance 100,000 cents
        let initial = await engine.sync()
        #expect(initial.balanceDisplay.formattedAmount == "1,000.00")
        #expect(bank.balance(of: "eva") == 100000)

        // Step 2: bank.setUnreachable(true); app syncs (fails), Eva sends 2500 to alex (fails with notConnectedToInternet)
        bank.setUnreachable(true)
        let failedSync = await engine.sync()
        #expect(failedSync.isStale)

        let sendResult = await engine.send(to: "alex", amountCents: 2500, description: "lunch")
        guard case .notSent(let reason) = sendResult else {
            Issue.record("Expected .notSent outcome when bank unreachable, got: \(sendResult)")
            return
        }
        #expect(!reason.isEmpty)

        // Assert after step 2:
        let midSnapshot = await engine.currentSnapshot()
        // - displayed balance is still 100000 (last known)
        #expect(midSnapshot.balanceDisplay.formattedAmount == "1,000.00")
        // - isStale == true (UI marker "possibly out of date")
        #expect(midSnapshot.isStale)
        // - exactly 1 row in state .notSent (not .unconfirmed: notConnectedToInternet means request never reached bank)
        #expect(midSnapshot.rows.count == 1)
        guard case .notSent = midSnapshot.rows.first?.status else {
            Issue.record("Expected row status .notSent, got: \(String(describing: midSnapshot.rows.first?.status))")
            return
        }
        // - bank holds 0 transactions from eva; paymentRequestCount == 0
        #expect(bank.transactionCount(from: "eva") == 0)
        #expect(bank.paymentRequestCount == 0)

        let attemptID = midSnapshot.state.attempts.first?.id
        #expect(attemptID != nil)

        // Step 3: PROVE must-have 7: switch unreachable off and run a plain sync,
        // assert the payment was NOT sent on its own BEFORE the user retries.
        bank.setUnreachable(false)
        let recoverySync = await engine.sync()

        #expect(bank.paymentRequestCount == 0) // Engine NEVER queued payment to go out on its own!
        #expect(recoverySync.rows.count == 1)
        guard case .notSent = recoverySync.rows.first?.status else {
            Issue.record("Expected row status to remain .notSent before user action")
            return
        }
        #expect(!recoverySync.isStale) // Sync succeeded, so staleness cleared

        // Step 4: bank.armBusy([.tooManyRequests(retryAfterSeconds: 1), .serviceUnavailable])
        bank.armBusy([.tooManyRequests(retryAfterSeconds: 1), .serviceUnavailable])

        // User retries: "Eva sends again" is the USER pressing "Try again" on the .notSent row
        guard let validAttemptID = attemptID else { return }
        let retryResult = await engine.retry(attemptID: validAttemptID)

        guard case .accepted(let retriedTx) = retryResult else {
            Issue.record("Expected retry to succeed with .accepted, got: \(retryResult)")
            return
        }
        #expect(retriedTx.status == .pending)

        // Assert at the end of payment:
        // - the retry made exactly 3 requests that reached the bank (429, 503, 201)
        #expect(bank.paymentRequestCount == 3)
        // - all carrying the identical idempotency key
        let postRequests = bank.requestLog.filter { $0.method == "POST" }
        #expect(postRequests.count == 3)
        let firstKey = postRequests.first?.idempotencyKey
        #expect(firstKey != nil)
        #expect(postRequests.allSatisfy { $0.idempotencyKey == firstKey })

        // - RecordingSleeper recorded a 1-second wait for 429 and exponential backoff wait for 503
        #expect(harness.sleeper.requestedDurations.count == 2)
        #expect(harness.sleeper.requestedDurations[0] == 1.0) // 429 Retry-After header
        #expect(harness.sleeper.requestedDurations[1] == 1.0) // 503 backoff for attempt 1 (0.5 * 2^1 = 1.0)

        // - final: 1 row .pending, then .completed after settle+sync, balance 97500, isStale false
        let pendingSnapshot = await engine.currentSnapshot()
        #expect(pendingSnapshot.rows.count == 1)
        #expect(pendingSnapshot.rows.first?.status == .pending)

        bank.settlePending()
        let finalSnapshot = await engine.sync()

        #expect(finalSnapshot.rows.count == 1)
        #expect(finalSnapshot.rows.first?.status == .completed)
        #expect(finalSnapshot.balanceDisplay.formattedAmount == "975.00")
        #expect(!finalSnapshot.isStale)
        #expect(bank.transactionCount(from: "eva") == 1)
    }

    @Test("Alternative user flow: User dismisses .notSent row and initiates a fresh payment")
    func userDismissesNotSentRowAndStartsFreshPayment() async throws {
        let harness = AppHarness()
        let bank = harness.bank
        guard let engine = harness.engine else {
            Issue.record("Harness engine not initialized")
            return
        }

        _ = await engine.sync()

        // Unreachable send produces .notSent attempt
        bank.setUnreachable(true)
        _ = await engine.send(to: "alex", amountCents: 2500, description: "lunch")

        let preDismiss = await engine.currentSnapshot()
        #expect(preDismiss.rows.count == 1)
        guard let attemptID = preDismiss.state.attempts.first?.id else {
            Issue.record("Missing attempt ID")
            return
        }

        // User dismisses the row
        try await engine.dismiss(attemptID: attemptID)

        let postDismiss = await engine.currentSnapshot()
        #expect(postDismiss.rows.isEmpty)
        #expect(postDismiss.state.attempts.isEmpty)

        // Bank reachable again; user initiates fresh payment
        bank.setUnreachable(false)
        let freshResult = await engine.send(to: "alex", amountCents: 2500, description: "lunch second try")

        guard case .accepted = freshResult else {
            Issue.record("Expected fresh payment to succeed, got: \(freshResult)")
            return
        }

        bank.settlePending()
        let finalSnapshot = await engine.sync()
        #expect(finalSnapshot.rows.count == 1)
        #expect(finalSnapshot.rows.first?.status == .completed)
        #expect(finalSnapshot.balanceDisplay.formattedAmount == "975.00")
        #expect(bank.transactionCount(from: "eva") == 1)
    }

    @Test("Busy budget exhaustion ends as .notSent('bank busy'), bank holds 0, and user retry succeeds")
    func busyBudgetExhaustedEndsAsNotSentAndUserRetryAfterwardsSucceeds() async throws {
        let harness = AppHarness()
        let bank = harness.bank
        guard let engine = harness.engine else {
            Issue.record("Harness engine not initialized")
            return
        }

        _ = await engine.sync()

        // Arm bank with 5 busy responses to exhaust the 5-attempt retry budget
        bank.armBusy([
            .serviceUnavailable,
            .serviceUnavailable,
            .serviceUnavailable,
            .serviceUnavailable,
            .serviceUnavailable
        ])

        let sendResult = await engine.send(to: "alex", amountCents: 3000, description: "dinner")
        guard case .notSent(let reason) = sendResult else {
            Issue.record("Expected .notSent when busy budget exhausted, got: \(sendResult)")
            return
        }
        #expect(reason == "bank busy")

        // Bank holds 0 transactions from Eva
        #expect(bank.transactionCount(from: "eva") == 0)

        let exhaustedSnapshot = await engine.currentSnapshot()
        #expect(exhaustedSnapshot.rows.count == 1)
        guard case .notSent(let rowReason) = exhaustedSnapshot.rows.first?.status else {
            Issue.record("Expected row status .notSent, got: \(String(describing: exhaustedSnapshot.rows.first?.status))")
            return
        }
        #expect(rowReason == "bank busy")

        guard let attemptID = exhaustedSnapshot.state.attempts.first?.id else {
            Issue.record("Missing attempt ID")
            return
        }

        // User retry afterwards succeeds (busy responses script is now empty, bank answers 201)
        let retryResult = await engine.retry(attemptID: attemptID)
        guard case .accepted = retryResult else {
            Issue.record("Expected retry to succeed with .accepted, got: \(retryResult)")
            return
        }

        bank.settlePending()
        let finalSnapshot = await engine.sync()
        #expect(finalSnapshot.rows.count == 1)
        #expect(finalSnapshot.rows.first?.status == .completed)
        #expect(finalSnapshot.balanceDisplay.formattedAmount == "970.00")
        #expect(bank.transactionCount(from: "eva") == 1)
    }
}
