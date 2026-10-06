//
//  DebugPanelView.swift
//  EvaLedger
//

import SwiftUI

#if DEBUG
public struct DebugPanelView: View {
    public let bank: FakeBank
    public let onBankMutated: () async -> Void

    @State private var isUnreachable: Bool = false
    @State private var holdIncoming: Bool = false

    public init(bank: FakeBank, onBankMutated: @escaping () async -> Void) {
        self.bank = bank
        self.onBankMutated = onBankMutated
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Actions") {
                    Button("Settle pending") {
                        bank.settlePending()
                        Task { await onBankMutated() }
                    }

                    Button("Mila pays Eva $10.00") {
                        bank.pay(from: "mila", toEva: "eva", amountCents: 1000, description: "coffee")
                        Task { await onBankMutated() }
                    }

                    Button("Noor pays Eva $17.08") {
                        bank.pay(from: "noor", toEva: "eva", amountCents: 1708, description: "lunch share")
                        Task { await onBankMutated() }
                    }

                    Button("Late reject last completed") {
                        // Find most recent completed transaction involving Eva
                        let completedTxns = bank.transactions(involving: "eva").filter { $0.status == .completed }
                        if let lastTx = completedTxns.last {
                            bank.lateReject(transactionID: lastTx.id, reason: "The receiving bank refused it")
                            Task { await onBankMutated() }
                        }
                    }
                }

                Section("Misbehavior Switches") {
                    Button("Arm Lost Answer (next payment)") {
                        bank.armLostAnswer()
                    }

                    Toggle("Bank Unreachable (offline)", isOn: $isUnreachable)
                        .onChange(of: isUnreachable) { _, newValue in
                            bank.setUnreachable(newValue)
                        }

                    Button("Arm Busy (429 then 503)") {
                        bank.armBusy([.tooManyRequests(retryAfterSeconds: 1), .serviceUnavailable])
                    }

                    Menu("Repeated Entries Mode") {
                        Button("Duplicate within page") {
                            bank.armRepeatedEntries(.duplicateWithinPage)
                        }
                        Button("Re-send previously delivered") {
                            bank.armRepeatedEntries(.resendPreviouslyDelivered)
                        }
                    }

                    Toggle("Hold incoming from feed", isOn: $holdIncoming)
                        .onChange(of: holdIncoming) { _, newValue in
                            bank.setHoldIncomingFromFeed(newValue)
                        }

                    Button("Release held feed transactions") {
                        bank.releaseHeldTransactions()
                        holdIncoming = false
                        Task { await onBankMutated() }
                    }
                }
            }
            .navigationTitle("Bank Remote Control")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
