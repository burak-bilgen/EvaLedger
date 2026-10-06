//
//  LedgerView.swift
//  EvaLedger
//

import SwiftUI

@MainActor
public struct LedgerView: View {
    @State public var viewModel: LedgerViewModel
    #if DEBUG
    @State private var showingDebugPanel = false
    private let debugControls: (any BankDebugControls)?

    public init(viewModel: LedgerViewModel, debugControls: (any BankDebugControls)? = nil) {
        _viewModel = State(initialValue: viewModel)
        self.debugControls = debugControls
    }
    #else
    public init(viewModel: LedgerViewModel) {
        _viewModel = State(initialValue: viewModel)
    }
    #endif

    public var body: some View {
        NavigationStack {
            List {
                // MARK: - Header
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Current Balance")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(viewModel.snapshot.balanceDisplay.formattedAmount.map { "$\($0)" } ?? "—")
                            .font(.system(size: 36, weight: .bold, design: .rounded))

                        if let asOf = viewModel.snapshot.balanceDisplay.asOf {
                            Text("as of \(asOf.formatted(date: .omitted, time: .standard))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not synced yet")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if viewModel.snapshot.isStale {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Possibly out of date")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.orange)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Send Payment Form
                Section("Send Payment") {
                    Picker("Recipient", selection: $viewModel.selectedRecipient) {
                        ForEach(viewModel.availableRecipients, id: \.self) { recipient in
                            Text(recipient.capitalized).tag(recipient)
                        }
                    }
                    .disabled(viewModel.isSending)

                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Amount (e.g. 25.00)", text: $viewModel.amountText)
                            .keyboardType(.decimalPad)
                            .disabled(viewModel.isSending)

                        if let error = viewModel.amountError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    TextField("Description", text: $viewModel.descriptionText)
                        .disabled(viewModel.isSending)

                    Button {
                        Task {
                            await viewModel.sendPayment()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isSending {
                                ProgressView()
                                    .padding(.trailing, 6)
                                Text("Sending…")
                            } else {
                                Text("Send Payment")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!viewModel.canSend)
                }

                // MARK: - Transactions Feed
                Section("Transactions") {
                    if viewModel.snapshot.rows.isEmpty {
                        Text("No transactions yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.snapshot.rows) { row in
                            TransactionRowView(
                                row: row,
                                onRetry: {
                                    if case .attempt(let id) = row.source {
                                        Task { await viewModel.retryPayment(attemptID: id) }
                                    }
                                },
                                onDismiss: {
                                    if case .attempt(let id) = row.source {
                                        Task { await viewModel.dismissAttempt(attemptID: id) }
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .navigationTitle("EvaLedger")
            .refreshable {
                await viewModel.refresh()
            }
            .task {
                await viewModel.onAppear()
            }
            .onDisappear {
                viewModel.onDisappear()
            }
            #if DEBUG
            .toolbar {
                if debugControls != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingDebugPanel = true
                        } label: {
                            Image(systemName: "ladybug.fill")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingDebugPanel) {
                if let debugControls {
                    DebugPanelView(
                        bank: debugControls,
                        onBankMutated: {
                            await viewModel.refresh()
                        },
                        onResetAll: {
                            debugControls.resetData()
                            await viewModel.resetData()
                        }
                    )
                }
            }
            #endif
        }
    }
}

// MARK: - Row View
private struct TransactionRowView: View {
    let row: TransactionRow
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.counterparty.capitalized)
                    .font(.headline)
                Spacer()
                Text(formatAmount(row.displayAmountCents))
                    .font(.headline)
                    .foregroundStyle(row.displayAmountCents < 0 ? Color.primary : Color.green)
            }

            if !row.description.isEmpty {
                Text(row.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                statusBadge(row.status)
                Spacer()

                if row.isRetryable {
                    Button("Try again", action: onRetry)
                        .buttonStyle(.bordered)
                        .font(.caption)
                }

                if row.isDismissible {
                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatAmount(_ cents: Int) -> String {
        let absFormatted = Money.format(cents: abs(cents))
        if cents < 0 {
            return "-$\(absFormatted)"
        } else {
            return "+$\(absFormatted)"
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: RowStatus) -> some View {
        switch status {
        case .sending:
            badge(text: "Sending…", color: .gray)
        case .unconfirmed:
            badge(text: "Not confirmed", color: .orange)
        case .pending:
            badge(text: "Pending", color: .blue)
        case .completed:
            badge(text: "Completed", color: .green)
        case .rejected(let reason):
            badge(text: "Rejected: \(reason)", color: .red)
        case .notSent(let reason):
            badge(text: "Not sent: \(reason)", color: .red)
        case .failed(let message):
            badge(text: "Failed: \(message)", color: .red)
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
