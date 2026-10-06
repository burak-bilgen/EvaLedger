//
//  FakeBankPersistenceTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

@Suite("FakeBank Persistence Tests")
struct FakeBankPersistenceTests {

    private func makeTempURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString).json")
    }

    private func postPayment(
        bank: FakeBank,
        session: URLSession,
        request: PaymentRequest
    ) async throws -> (Data, HTTPURLResponse) {
        var urlReq = URLRequest(url: bank.baseURL.appendingPathComponent("v1/payments"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await session.data(for: urlReq)
        let httpResponse = response as! HTTPURLResponse
        return (data, httpResponse)
    }

    private func getFeed(
        bank: FakeBank,
        session: URLSession,
        cursor: Int? = nil
    ) async throws -> (FeedResponse, HTTPURLResponse) {
        var comps = URLComponents(url: bank.baseURL.appendingPathComponent("v1/transactions"), resolvingAgainstBaseURL: false)!
        if let cursor = cursor {
            comps.queryItems = [URLQueryItem(name: "cursor", value: String(cursor))]
        }
        var urlReq = URLRequest(url: comps.url!)
        urlReq.httpMethod = "GET"

        let (data, response) = try await session.data(for: urlReq)
        let httpResponse = response as! HTTPURLResponse
        let feed = try JSONDecoder().decode(FeedResponse.self, from: data)
        return (feed, httpResponse)
    }

    @Test("FakeBank state survives across new instance when storageURL is provided")
    func fakeBankStateSurvivesAcrossInstancesWithStorageURL() async throws {
        let bankFile = makeTempURL(prefix: "test_bank")
        let host = "\(UUID().uuidString).bank.test"

        let cursor1: Int?
        let req1 = PaymentRequest(toUsername: "alex", amountCents: 2500, description: "lunch", idempotencyKey: "k_persisted")

        do {
            let bank = FakeBank(uniqueHost: host, storageURL: bankFile)
            let session = bank.makeSession()

            // 1. Make payment from Eva -> Alex 2500
            let (data1, resp1) = try await postPayment(bank: bank, session: session, request: req1)
            #expect(resp1.statusCode == 201)
            let payment1 = try JSONDecoder().decode(PaymentResponse.self, from: data1)
            #expect(payment1.transaction.id == "txn_00000001")

            // 2. Settle payment
            bank.settlePending()
            #expect(bank.balance(of: "eva") == 97500)
            #expect(bank.balance(of: "alex") == 102500)

            // 3. Incoming payment from Mila -> Eva 1000
            bank.pay(from: "mila", toEva: "eva", amountCents: 1000, description: "coffee")

            // 4. Balance ahead incoming payment from Noor -> Eva 1708
            bank.setHoldIncomingFromFeed(true)
            bank.pay(from: "noor", toEva: "eva", amountCents: 1708, description: "split")

            // 5. Late reject payment 1 (Eva refunded)
            bank.lateReject(transactionID: payment1.transaction.id, reason: "Card processor error")
            #expect(bank.balance(of: "eva") == 101708)

            // Verify initial feed
            let (feed1, _) = try await getFeed(bank: bank, session: session)
            cursor1 = feed1.cursor
            #expect(cursor1 != nil)
        }

        // RESTART BANK 2 from same storageURL
        let bank2 = FakeBank(uniqueHost: host, storageURL: bankFile)
        let session2 = bank2.makeSession()

        // Assert balances match
        #expect(bank2.balance(of: "eva") == 101708)
        #expect(bank2.balance(of: "alex") == 100000)
        #expect(bank2.balance(of: "mila") == 99000)
        #expect(bank2.balance(of: "noor") == 98292)

        // Assert transaction count
        #expect(bank2.transactions(involving: "eva").count == 3)

        // Assert idempotency replay across instances
        let (replayData, replayResp) = try await postPayment(bank: bank2, session: session2, request: req1)
        #expect(replayResp.statusCode == 200)
        let replayPayment = try JSONDecoder().decode(PaymentResponse.self, from: replayData)
        #expect(replayPayment.replayed == true)
        #expect(replayPayment.transaction.id == "txn_00000001")

        // Assert NO ID collision on next payment
        let reqNew = PaymentRequest(toUsername: "alex", amountCents: 500, description: "tea", idempotencyKey: "k_new")
        let (newData, newResp) = try await postPayment(bank: bank2, session: session2, request: reqNew)
        #expect(newResp.statusCode == 201)
        let newPayment = try JSONDecoder().decode(PaymentResponse.self, from: newData)
        #expect(newPayment.transaction.id == "txn_00000004")

        // Assert feed continuity (cursor does not regress)
        let (feed2, _) = try await getFeed(bank: bank2, session: session2, cursor: cursor1)
        #expect(feed2.cursor != nil)
        if let c1 = cursor1, let c2 = feed2.cursor {
            #expect(c2 >= c1)
        }

        // Release held transactions on restarted bank
        bank2.releaseHeldTransactions()
        let (feedAfterRelease, _) = try await getFeed(bank: bank2, session: session2, cursor: feed2.cursor)
        #expect(feedAfterRelease.transactions.contains(where: { $0.fromUsername == "noor" }))
    }

    @Test("App and FakeBank both survive process kill and rebuild from disk end-to-end")
    func appAndBankBothSurviveProcessKillEndToEnd() async throws {
        let bankFile = makeTempURL(prefix: "e2e_bank")
        let ledgerFile = makeTempURL(prefix: "e2e_ledger")
        let host = "\(UUID().uuidString).bank.test"

        // PHASE 1: Running app and bank
        do {
            let bankA = FakeBank(uniqueHost: host, storageURL: bankFile)
            let filePersistenceA = FileLedgerPersistence(fileURL: ledgerFile)
            let storeA = try LedgerStore(persistence: filePersistenceA)
            let sleeperA = RecordingSleeper()
            let clientA = URLSessionBankClient(session: bankA.makeSession(), baseURL: bankA.baseURL, sleeper: sleeperA)
            let engineA = PaymentEngine(
                store: storeA,
                bankClient: clientA,
                retryPolicy: BusyRetryPolicy(sleeper: sleeperA),
                idGenerator: DeterministicIDGenerator(),
                clock: FixedClock()
            )

            // Initial sync
            _ = await engineA.sync()

            // Eva sends 2500 to alex
            let sendRes = await engineA.send(to: "alex", amountCents: 2500, description: "lunch")
            guard case .accepted = sendRes else {
                Issue.record("Expected .accepted")
                return
            }

            // Bank settles and Mila pays Eva
            bankA.settlePending()
            bankA.pay(from: "mila", toEva: "eva", amountCents: 1000, description: "coffee")

            // Sync again
            _ = await engineA.sync()
        }

        // SIMULATE REAL CRASH / PROCESS TERMINATION: all Phase 1 in-memory objects deallocated

        // PHASE 2: Brand new process launch: rebuild app and bank from disk files
        let bankB = FakeBank(uniqueHost: host, storageURL: bankFile)
        let filePersistenceB = FileLedgerPersistence(fileURL: ledgerFile)
        let storeB = try LedgerStore(persistence: filePersistenceB)
        let sleeperB = RecordingSleeper()
        let clientB = URLSessionBankClient(session: bankB.makeSession(), baseURL: bankB.baseURL, sleeper: sleeperB)
        let engineB = PaymentEngine(
            store: storeB,
            bankClient: clientB,
            retryPolicy: BusyRetryPolicy(sleeper: sleeperB),
            idGenerator: DeterministicIDGenerator(),
            clock: FixedClock()
        )

        // Relaunch recovery and sync
        _ = try await engineB.recoverOnLaunch()
        let snapshotB = await engineB.sync()

        // Assert correct state restored:
        #expect(snapshotB.rows.count == 2)
        let alexRow = snapshotB.rows.first(where: { $0.counterparty == "alex" })
        let milaRow = snapshotB.rows.first(where: { $0.counterparty == "mila" })
        #expect(alexRow?.status == .completed)
        #expect(alexRow?.displayAmountCents == -2500)
        #expect(milaRow?.status == .pending)
        #expect(milaRow?.displayAmountCents == 1000)

        // Balance is verbatim from bank: 100000 - 2500 = 97500 (Mila pending not credited until settle)
        #expect(snapshotB.balanceDisplay.formattedAmount == "975.00")
        #expect(!snapshotB.isStale)
    }

    @Test("FakeBank records persistence error when storageURL is unwritable and in-memory bank continues working")
    func fakeBankRecordsPersistenceErrorAndKeepsWorking() async throws {
        let unwritableURL = URL(fileURLWithPath: "/dev/null/forbidden/bank.json")
        let host = "\(UUID().uuidString).bank.test"
        let bank = FakeBank(uniqueHost: host, storageURL: unwritableURL)

        // Action triggering persistence
        bank.pay(from: "mila", toEva: "eva", amountCents: 1000, description: "coffee")

        // Assert error is recorded
        #expect(bank.lastPersistenceError != nil)

        // Assert in-memory bank continues working
        #expect(bank.balance(of: "eva") == 100000)
        bank.settlePending()
        #expect(bank.balance(of: "eva") == 101000)
    }
}
