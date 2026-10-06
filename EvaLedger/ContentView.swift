//
//  ContentView.swift
//  EvaLedger
//

import SwiftUI

@MainActor
struct ContentView: View {
    @State private var viewModel = LedgerViewModel(
        engine: AppEnvironment.shared.engine,
        bank: AppEnvironment.shared.bank
    )

    var body: some View {
        LedgerView(viewModel: viewModel)
    }
}
