//
//  AppEnvironment.swift
//  EvaLedger
//

import Foundation

@MainActor
public final class AppEnvironment {
    public let bank: FakeBank
    public let engine: PaymentEngine
    public let storageURL: URL
    public let bankStorageURL: URL?

    public static let shared: AppEnvironment = AppEnvironment.makeProduction()

    public init(bank: FakeBank, engine: PaymentEngine, storageURL: URL, bankStorageURL: URL? = nil) {
        self.bank = bank
        self.engine = engine
        self.storageURL = storageURL
        self.bankStorageURL = bankStorageURL
    }

    public static func makeProduction() -> AppEnvironment {
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        let bankStorageURL = appSupportDir.appendingPathComponent("evaledger_bank.json")
        let storageURL = appSupportDir.appendingPathComponent("evaledger_ledger.json")

        let bank = FakeBank(uniqueHost: "api.evaledger.local", storageURL: bankStorageURL)
        let persistence = FileLedgerPersistence(fileURL: storageURL)
        do {
            let store = try LedgerStore(persistence: persistence)
            let session = bank.makeSession()
            let bankClient = URLSessionBankClient(session: session, baseURL: bank.baseURL)
            let engine = PaymentEngine(
                store: store,
                bankClient: bankClient,
                retryPolicy: BusyRetryPolicy(sleeper: RealSleeper()),
                idGenerator: SystemIDGenerator(),
                clock: SystemClock()
            )
            return AppEnvironment(bank: bank, engine: engine, storageURL: storageURL, bankStorageURL: bankStorageURL)
        } catch {
            fatalError("Failed to initialize AppEnvironment: \(error)")
        }
    }

    public static func makePreview() -> AppEnvironment {
        let bank = FakeBank(uniqueHost: "preview.evaledger.local")
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("preview_\(UUID().uuidString).json")
        let persistence = FileLedgerPersistence(fileURL: tempURL)
        do {
            let store = try LedgerStore(persistence: persistence)
            let session = bank.makeSession()
            let bankClient = URLSessionBankClient(session: session, baseURL: bank.baseURL)
            let engine = PaymentEngine(
                store: store,
                bankClient: bankClient,
                retryPolicy: BusyRetryPolicy(sleeper: RealSleeper()),
                idGenerator: SystemIDGenerator(),
                clock: SystemClock()
            )
            return AppEnvironment(bank: bank, engine: engine, storageURL: tempURL)
        } catch {
            fatalError("Failed to initialize Preview AppEnvironment: \(error)")
        }
    }
}
