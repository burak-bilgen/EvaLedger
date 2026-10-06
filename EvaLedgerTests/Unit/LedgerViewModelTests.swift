//
//  LedgerViewModelTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

@Suite("LedgerViewModel Tests")
@MainActor
struct LedgerViewModelTests {

    @Test("Send button is disabled while sending or when form is invalid")
    func sendButtonDisabledWhileSending() async {
        let harness = AppHarness()
        guard let engine = harness.engine else {
            Issue.record("Missing engine")
            return
        }

        let viewModel = LedgerViewModel(engine: engine, bank: harness.bank)

        // Empty form: cannot send
        #expect(!viewModel.canSend)

        // Valid amount entered: can send
        viewModel.amountText = "25.00"
        #expect(viewModel.canSend)

        // When sending starts, send is disabled
        harness.bank.gateNextPayment()
        let sendTask = Task {
            await viewModel.sendPayment()
        }

        await harness.bank.waitUntilGateReached()

        // Mid-flight: isSending is true, so canSend MUST be false to prevent double taps
        #expect(viewModel.isSending)
        #expect(!viewModel.canSend)

        // Release gate to complete send
        harness.bank.releaseGate()
        await sendTask.value

        #expect(!viewModel.isSending)
    }

    @Test("Error message appears for invalid amount inputs")
    func errorTextForInvalidAmount() {
        let harness = AppHarness()
        guard let engine = harness.engine else {
            Issue.record("Missing engine")
            return
        }

        let viewModel = LedgerViewModel(engine: engine, bank: harness.bank)

        // Empty input shows no error yet
        viewModel.amountText = ""
        #expect(viewModel.amountError == nil)
        #expect(!viewModel.canSend)

        // Negative or non-numeric amount shows error
        viewModel.amountText = "-10.00"
        #expect(viewModel.amountError != nil)
        #expect(!viewModel.canSend)

        viewModel.amountText = "not_a_number"
        #expect(viewModel.amountError != nil)
        #expect(!viewModel.canSend)

        // Valid amount clears error and enables send
        viewModel.amountText = "15.50"
        #expect(viewModel.amountError == nil)
        #expect(viewModel.canSend)
    }

    @Test("Staleness banner state is accurate: stale at launch, clears after sync, reappears on offline error")
    func bannerAppearsWhenStale() async {
        let harness = AppHarness()
        guard let engine = harness.engine else {
            Issue.record("Missing engine")
            return
        }

        let viewModel = LedgerViewModel(engine: engine, bank: harness.bank)

        // At initialization, state is stale (not synced)
        #expect(viewModel.snapshot.isStale)

        // After successful refresh, staleness clears
        await viewModel.refresh()
        #expect(!viewModel.snapshot.isStale)

        // When bank becomes unreachable, refresh fails and staleness reappears
        harness.bank.setUnreachable(true)
        await viewModel.refresh()
        #expect(viewModel.snapshot.isStale)
    }
}
