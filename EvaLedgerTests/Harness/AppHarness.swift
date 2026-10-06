//
//  AppHarness.swift
//  EvaLedgerTests
//

import Foundation
@testable import EvaLedger

public final class AppHarness: @unchecked Sendable {
    public let bank: FakeBank
    public let storageURL: URL
    public private(set) var filePersistence: FileLedgerPersistence
    public private(set) var frozenPersistence: FrozenPersistence
    public private(set) var sleeper: RecordingSleeper
    public private(set) var idGenerator: DeterministicIDGenerator
    public private(set) var clock: FixedClock
    public private(set) var bankClient: URLSessionBankClient
    public private(set) var store: LedgerStore?
    public private(set) var engine: PaymentEngine?

    public init(bank: FakeBank? = nil, storageURL: URL? = nil) {
        let theBank = bank ?? FakeBank()
        self.bank = theBank
        let url = storageURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("evaledger_harness_\(UUID().uuidString).json")
        self.storageURL = url

        let basePersistence = FileLedgerPersistence(fileURL: url)
        self.filePersistence = basePersistence
        let frozen = FrozenPersistence(wrapping: basePersistence)
        self.frozenPersistence = frozen
        self.sleeper = RecordingSleeper()
        self.idGenerator = DeterministicIDGenerator()
        self.clock = FixedClock()

        let session = theBank.makeSession()
        let client = URLSessionBankClient(session: session, baseURL: theBank.baseURL, sleeper: self.sleeper)
        self.bankClient = client

        do {
            let theStore = try LedgerStore(persistence: frozen)
            self.store = theStore
            let theEngine = PaymentEngine(
                store: theStore,
                bankClient: client,
                retryPolicy: BusyRetryPolicy(sleeper: self.sleeper),
                idGenerator: self.idGenerator,
                clock: self.clock
            )
            self.engine = theEngine
        } catch {
            fatalError("Failed to init AppHarness: \(error)")
        }
    }

    /// Freezes persistence and drops all in-memory references, simulating an immediate process kill.
    public func kill() {
        frozenPersistence.freeze()
        store = nil
        engine = nil
    }

    /// Relaunches the app from disk against the same FakeBank instance.
    @discardableResult
    public func relaunch() async throws -> PaymentEngine {
        let basePersistence = FileLedgerPersistence(fileURL: storageURL)
        self.filePersistence = basePersistence
        let freshFrozen = FrozenPersistence(wrapping: basePersistence)
        self.frozenPersistence = freshFrozen

        let freshStore = try LedgerStore(persistence: freshFrozen)
        self.store = freshStore

        let session = bank.makeSession()
        let client = URLSessionBankClient(session: session, baseURL: bank.baseURL, sleeper: self.sleeper)
        self.bankClient = client

        let freshEngine = PaymentEngine(
            store: freshStore,
            bankClient: client,
            retryPolicy: BusyRetryPolicy(sleeper: self.sleeper),
            idGenerator: self.idGenerator,
            clock: self.clock
        )
        self.engine = freshEngine

        _ = try await freshEngine.recoverOnLaunch()
        return freshEngine
    }

    public func readPersistedState() throws -> LedgerState? {
        try filePersistence.load()
    }
}
