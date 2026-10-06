//
//  ContentView.swift
//  EvaLedger
//

import SwiftUI

@MainActor
struct ContentView: View {
    @State private var viewModel = LedgerViewModel(
        engine: AppEnvironment.shared.engine
    )

    var body: some View {
        #if DEBUG
        LedgerView(viewModel: viewModel, debugControls: AppEnvironment.shared.bank)
        #else
        LedgerView(viewModel: viewModel)
        #endif
    }
}
