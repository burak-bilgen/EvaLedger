//
//  LedgerViewModel.swift
//  EvaLedger
//

import Foundation
import Observation

@Observable
@MainActor
public final class LedgerViewModel {
    public let engine: PaymentEngine

    public private(set) var snapshot: LedgerSnapshot
    public var selectedRecipient: String = "alex"
    public var amountText: String = "" {
        didSet {
            validateAmount()
        }
    }
    public var descriptionText: String = ""
    public private(set) var amountError: String? = nil
    public private(set) var isSending: Bool = false

    public let availableRecipients = ["alex", "mila", "noor"]

    private var pollingTask: Task<Void, Never>? = nil

    public init(engine: PaymentEngine) {
        self.engine = engine
        self.snapshot = LedgerSnapshot(state: LedgerState(), isStale: true)
    }

    public func onAppear() async {
        do {
            self.snapshot = try await engine.recoverOnLaunch()
        } catch {
            self.snapshot = await engine.currentSnapshot()
        }
        self.snapshot = await engine.sync()
        startPolling()
    }

    public func onDisappear() {
        stopPolling()
    }

    public func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { break }
                let newSnapshot = await self.engine.sync()
                self.snapshot = newSnapshot
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    @discardableResult
    public func validateAmount() -> Bool {
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            amountError = nil
            return false
        }
        do {
            _ = try Money.parse(input: trimmed)
            amountError = nil
            return true
        } catch {
            amountError = error.errorDescription ?? "Enter a valid amount"
            return false
        }
    }

    public var canSend: Bool {
        !isSending && validateAmount() && !selectedRecipient.isEmpty
    }

    public func sendPayment() async {
        guard canSend else { return }
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cents = try? Money.parse(input: trimmed), cents > 0 else { return }

        isSending = true
        let recipient = selectedRecipient
        let desc = descriptionText
        let result = await engine.send(to: recipient, amountCents: cents, description: desc)

        // Clear input form upon submission
        amountText = ""
        descriptionText = ""
        isSending = false
        self.snapshot = await engine.currentSnapshot()

        // Per Prompt 13: View model triggers a post-send sync for accepted or ambiguous outcomes
        switch result {
        case .accepted, .unconfirmed:
            self.snapshot = await engine.sync()
        default:
            break
        }
    }

    public func retryPayment(attemptID: UUID) async {
        isSending = true
        let result = await engine.retry(attemptID: attemptID)
        isSending = false
        self.snapshot = await engine.currentSnapshot()

        switch result {
        case .accepted, .unconfirmed:
            self.snapshot = await engine.sync()
        default:
            break
        }
    }

    public func dismissAttempt(attemptID: UUID) async {
        try? await engine.dismiss(attemptID: attemptID)
        self.snapshot = await engine.currentSnapshot()
    }

    public func refresh() async {
        self.snapshot = await engine.sync()
    }

    public func resetData() async {
        try? await engine.resetData()
        self.snapshot = await engine.sync()
    }
}
