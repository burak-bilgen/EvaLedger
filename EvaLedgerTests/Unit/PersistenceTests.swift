//
//  PersistenceTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

struct PersistenceTests {

    private func makeTempURL() -> URL {
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("ledger.json")
    }

    @Test func saveAndLoadRoundTripAllAttemptStates() throws {
        let fileURL = makeTempURL()
        let persistence = FileLedgerPersistence(fileURL: fileURL)

        var state = LedgerState(cursor: 5, bankBalanceCents: 97500, balanceAsOf: Date())
        let tx = Transaction(id: "tx_1", fromUsername: "eva", toUsername: "alex", amountCents: 2500, description: "lunch", status: .completed)
        state.transactions["tx_1"] = tx
        state.firstSeenOrders["tx_1"] = 0

        let attempts: [PaymentAttempt] = [
            PaymentAttempt(id: UUID(), idempotencyKey: "k1", toUsername: "alex", amountCents: 100, description: "a1", createdAt: Date(), state: .sending),
            PaymentAttempt(id: UUID(), idempotencyKey: "k2", toUsername: "mila", amountCents: 200, description: "a2", createdAt: Date(), state: .unconfirmed),
            PaymentAttempt(id: UUID(), idempotencyKey: "k3", toUsername: "noor", amountCents: 300, description: "a3", createdAt: Date(), state: .notSent(reason: "offline")),
            PaymentAttempt(id: UUID(), idempotencyKey: "k4", toUsername: "alex", amountCents: 400, description: "a4", createdAt: Date(), state: .failed(code: "err", message: "fail"))
        ]
        state.attempts = attempts

        try persistence.save(state)

        let loaded = try persistence.load()
        #expect(loaded != nil)
        #expect(loaded?.cursor == 5)
        #expect(loaded?.bankBalanceCents == 97500)
        #expect(loaded?.transactions.count == 1)
        #expect(loaded?.attempts.count == 4)
        #expect(loaded?.attempts[0].state == .sending)
        #expect(loaded?.attempts[1].state == .unconfirmed)
        #expect(loaded?.attempts[2].state == .notSent(reason: "offline"))
        #expect(loaded?.attempts[3].state == .failed(code: "err", message: "fail"))
    }

    @Test func missingFileReturnsNil() throws {
        let fileURL = makeTempURL()
        let persistence = FileLedgerPersistence(fileURL: fileURL)
        let state = try persistence.load()
        #expect(state == nil)
    }

    @Test func corruptFileCreatesBackupAndThrowsTypedError() throws {
        let fileURL = makeTempURL()
        let parentDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let corruptContent = "{\"invalid_json\": true".data(using: .utf8)!
        try corruptContent.write(to: fileURL)

        let persistence = FileLedgerPersistence(fileURL: fileURL)

        do {
            _ = try persistence.load()
            Issue.record("Expected corruption error")
        } catch let error as PersistenceError {
            switch error {
            case .fileCorrupt(let url, let backupURL, _):
                #expect(url == fileURL)
                #expect(FileManager.default.fileExists(atPath: backupURL.path))
            default:
                Issue.record("Expected .fileCorrupt error")
            }
        }
    }

    @Test func futureSchemaVersionThrowsUnsupportedSchemaVersion() throws {
        let fileURL = makeTempURL()
        let parentDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let futureJSON = """
        {
          "schema_version": 999,
          "transactions": {},
          "first_seen_orders": {},
          "next_order": 0,
          "attempts": []
        }
        """.data(using: .utf8)!
        try futureJSON.write(to: fileURL)

        let persistence = FileLedgerPersistence(fileURL: fileURL)

        do {
            _ = try persistence.load()
            Issue.record("Expected unsupportedSchemaVersion error")
        } catch let error as PersistenceError {
            switch error {
            case .unsupportedSchemaVersion(let version):
                #expect(version == 999)
            default:
                Issue.record("Expected .unsupportedSchemaVersion error")
            }
        }
    }

    @Test func frozenPersistenceSilentlyDropsSaves() throws {
        let fileURL = makeTempURL()
        let filePersistence = FileLedgerPersistence(fileURL: fileURL)
        let frozen = FrozenPersistence(wrapping: filePersistence)

        let initial = LedgerState(cursor: 1, bankBalanceCents: 100000)
        try frozen.save(initial)

        let loadedInitial = try frozen.load()
        #expect(loadedInitial?.bankBalanceCents == 100000)

        // Freeze
        frozen.freeze()

        // Attempt second save
        let modified = LedgerState(cursor: 2, bankBalanceCents: 90000)
        try frozen.save(modified)

        // Must still return initial state
        let loadedAfterFreeze = try frozen.load()
        #expect(loadedAfterFreeze?.bankBalanceCents == 100000)
    }

    @Test func ledgerStoreRollsBackInMemoryStateOnPersistenceFailure() async throws {
        struct FailingPersistence: Persistence {
            func load() throws -> LedgerState? { return nil }
            func save(_ state: LedgerState) throws {
                throw PersistenceError.writeFailed(NSError(domain: "disk_full", code: 1))
            }
        }

        let store = try LedgerStore(persistence: FailingPersistence(), initialState: LedgerState(bankBalanceCents: 100000))

        do {
            try await store.mutate { state in
                state.bankBalanceCents = 50000
            }
            Issue.record("Expected save error")
        } catch {
            // Memory was rolled back to previous snapshot!
            let current = await store.snapshot()
            #expect(current.bankBalanceCents == 100000)
        }
    }

    @Test func concurrentMutationsNeverLoseAnUpdate() async throws {
        let fileURL = makeTempURL()
        let persistence = FileLedgerPersistence(fileURL: fileURL)
        let store = try LedgerStore(persistence: persistence, initialState: LedgerState(nextOrder: 0))

        let taskCount = 30
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    try? await store.mutate { state in
                        let id = "tx_\(i)"
                        state.transactions[id] = Transaction(id: id, fromUsername: "eva", toUsername: "alex", amountCents: 100, description: "c", status: .completed)
                        state.nextOrder += 1
                    }
                }
            }
        }

        let finalSnapshot = await store.snapshot()
        #expect(finalSnapshot.transactions.count == taskCount)
        #expect(finalSnapshot.nextOrder == taskCount)

        // Verify disk also has all updates
        let onDisk = try persistence.load()
        #expect(onDisk?.transactions.count == taskCount)
    }

    @Test func persistenceFailureDuringPaymentOutcomeDoesNotLeaveRowStuckInSending() async throws {
        let harness = AppHarness()
        let bank = harness.bank
        guard let engine = harness.engine else {
            Issue.record("Harness engine not initialized")
            return
        }

        // Arm bank unreachable so outcome is definitelyNotSent
        bank.setUnreachable(true)

        // Save 0 is write-ahead save. Save 1 is applyPaymentOutcome update.
        // Write-ahead succeeds; outcome persistence throws error.
        harness.frozenPersistence.armThrowAfterSuccessfulSaves(1)

        let result = await engine.send(to: "alex", amountCents: 2500, description: "lunch")
        guard case .unconfirmed = result else {
            Issue.record("Expected .unconfirmed fallback when persistence fails on outcome, got \(result)")
            return
        }

        // Snapshot from engine must NOT have row stuck in .sending
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows.first?.status == .unconfirmed)

        // ViewModel shows .unconfirmed and allows subsequent payment
        let viewModel = await LedgerViewModel(engine: engine, bank: bank)
        await MainActor.run {
            #expect(!viewModel.isSending)
            viewModel.amountText = "15.00"
            #expect(viewModel.canSend)
        }
    }
}
