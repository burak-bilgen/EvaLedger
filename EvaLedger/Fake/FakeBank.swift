//
//  FakeBank.swift
//  EvaLedger
//

import Foundation

nonisolated public enum BusyResponse: Equatable, Sendable {
    case serviceUnavailable
    case tooManyRequests(retryAfterSeconds: Int)
}

nonisolated public enum RepeatedEntriesMode: Equatable, Sendable {
    case duplicateWithinPage
    case resendPreviouslyDelivered
}

nonisolated public struct BankRequestLogEntry: Equatable, Sendable {
    public let method: String
    public let path: String
    public let idempotencyKey: String?
    public let statusCode: Int

    public init(method: String, path: String, idempotencyKey: String?, statusCode: Int) {
        self.method = method
        self.path = path
        self.idempotencyKey = idempotencyKey
        self.statusCode = statusCode
    }
}

/// Fake bank HTTP server implemented via a registered URLProtocol.
/// State is isolated per instance using a unique `.bank.test` hostname.
nonisolated public final class FakeBank: @unchecked Sendable {
    // MARK: - Registry for URLProtocol routing
    private static let registryLock = NSRecursiveLock()
    private static var registry: [String: FakeBank] = [:]

    private static func register(_ bank: FakeBank, host: String) {
        var oldBank: FakeBank?
        registryLock.lock()
        oldBank = registry.updateValue(bank, forKey: host)
        registryLock.unlock()
        _ = oldBank
    }

    private static func unregister(bank: FakeBank, host: String) {
        registryLock.lock()
        defer { registryLock.unlock() }
        if registry[host] === bank {
            registry.removeValue(forKey: host)
        }
    }

    fileprivate static func bank(for host: String) -> FakeBank? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return registry[host]
    }

    // MARK: - Properties & State
    public let host: String
    public let baseURL: URL
    public let storageURL: URL?

    private let lock = NSLock()
    private var balances: [String: Int] = [
        "eva": 100000,
        "alex": 100000,
        "mila": 100000,
        "noor": 100000
    ]
    private var transactions: [String: Transaction] = [:]
    private var changeLog: [(seq: Int, txId: String)] = []
    private var nextSeq: Int = 1
    private var idempotencyMap: [String: [String: String]] = [:] // sender -> [key: txId]
    private var _paymentRequestCount: Int = 0
    private var _requestLog: [BankRequestLogEntry] = []
    private var txIdCounter: Int = 0

    // Switches
    private var lostAnswerArmed: Bool = false
    private var isUnreachable: Bool = false
    private var busyScript: [BusyResponse] = []
    private var repeatedEntriesMode: RepeatedEntriesMode? = nil
    private var deliveredTxIDs: Set<String> = []
    private var holdIncomingFromFeed: Bool = false
    private var heldTxIDs: [String] = []
    private var creditedToRecipientTxIDs: Set<String> = []

    // Test staging gates
    private var gateNextPaymentArmed: Bool = false
    private var gateReachedContinuation: CheckedContinuation<Void, Never>?
    private var gateReleaseContinuation: CheckedContinuation<Void, Never>?

    private var hangNextPaymentArmed: Bool = false
    private var hangingContinuation: CheckedContinuation<Void, Never>?
    private var hangReachedContinuation: CheckedContinuation<Void, Never>?
    private var onPaymentCreatedHook: (@Sendable () -> Void)?

    // MARK: - State Persistence
    private struct PersistedBankState: Codable {
        struct ChangeLogEntry: Codable {
            let seq: Int
            let txId: String
        }

        var balances: [String: Int]
        var transactions: [String: Transaction]
        var changeLog: [ChangeLogEntry]
        var nextSeq: Int
        var idempotencyMap: [String: [String: String]]
        var txIdCounter: Int
        var creditedToRecipientTxIDs: [String]
        var heldTxIDs: [String]
        var deliveredTxIDs: [String]
        var holdIncomingFromFeed: Bool
    }

    private func loadPersistedStateLocked() {
        guard let storageURL else { return }
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let state = try JSONDecoder().decode(PersistedBankState.self, from: data)
            self.balances = state.balances
            self.transactions = state.transactions
            self.changeLog = state.changeLog.map { ($0.seq, $0.txId) }
            self.nextSeq = state.nextSeq
            self.idempotencyMap = state.idempotencyMap
            self.txIdCounter = state.txIdCounter
            self.creditedToRecipientTxIDs = Set(state.creditedToRecipientTxIDs)
            self.heldTxIDs = state.heldTxIDs
            self.deliveredTxIDs = Set(state.deliveredTxIDs)
            self.holdIncomingFromFeed = state.holdIncomingFromFeed
        } catch {
            // Silently fall back to fresh state if corrupted
        }
    }

    private func persistStateLocked() {
        guard let storageURL else { return }
        let state = PersistedBankState(
            balances: balances,
            transactions: transactions,
            changeLog: changeLog.map { PersistedBankState.ChangeLogEntry(seq: $0.seq, txId: $0.txId) },
            nextSeq: nextSeq,
            idempotencyMap: idempotencyMap,
            txIdCounter: txIdCounter,
            creditedToRecipientTxIDs: Array(creditedToRecipientTxIDs),
            heldTxIDs: heldTxIDs,
            deliveredTxIDs: Array(deliveredTxIDs),
            holdIncomingFromFeed: holdIncomingFromFeed
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            let dir = storageURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Persistence error ignored or logged
        }
    }

    public init(uniqueHost: String = UUID().uuidString + ".bank.test", storageURL: URL? = nil) {
        self.host = uniqueHost
        self.storageURL = storageURL
        self.baseURL = URL(string: "https://\(uniqueHost)") ?? URL(fileURLWithPath: "/")
        FakeBank.register(self, host: uniqueHost)
        if storageURL != nil {
            lock.lock()
            loadPersistedStateLocked()
            lock.unlock()
        }
    }

    deinit {
        cancelHanging()
        releaseGate()
        FakeBank.unregister(bank: self, host: host)
    }

    public func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeBankURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - Misbehavior Switches

    /// Arms the fake so the NEXT POST /v1/payments is processed normally (payment created, balance debited),
    /// but the connection drops and returns URLError(.networkConnectionLost). One-shot.
    public func armLostAnswer() {
        lock.lock()
        defer { lock.unlock() }
        lostAnswerArmed = true
    }

    /// While true, every request fails immediately with URLError(.notConnectedToInternet) and bank state is untouched.
    public func setUnreachable(_ unreachable: Bool) {
        lock.lock()
        defer { lock.unlock() }
        isUnreachable = unreachable
    }

    public func armUnreachable() {
        setUnreachable(true)
    }

    public func disarmUnreachable() {
        setUnreachable(false)
    }

    /// Answers the next requests in order with 503 or 429 + Retry-After. Bank state is untouched.
    public func armBusy(_ script: [BusyResponse]) {
        lock.lock()
        defer { lock.unlock() }
        busyScript.append(contentsOf: script)
    }

    /// Controls duplicate transactions on the NEXT feed page. One-shot.
    public func armRepeatedEntries(_ mode: RepeatedEntriesMode) {
        lock.lock()
        defer { lock.unlock() }
        repeatedEntriesMode = mode
    }

    /// While true, incoming payments to Eva credit her balance immediately but are excluded from the feed.
    public func setHoldIncomingFromFeed(_ hold: Bool) {
        lock.lock()
        defer { lock.unlock() }
        holdIncomingFromFeed = hold
        persistStateLocked()
    }

    /// Re-appends held incoming transactions to the feed change log with brand-new sequence numbers.
    public func releaseHeldTransactions() {
        lock.lock()
        defer { lock.unlock() }
        for txId in heldTxIDs {
            changeLog.append((seq: nextSeq, txId: txId))
            nextSeq += 1
        }
        heldTxIDs.removeAll()
        holdIncomingFromFeed = false
        persistStateLocked()
    }

    /// Flips a completed transaction to rejected, refunds Eva, reverses counterparty credit, and appends a feed change.
    public func lateReject(transactionID: String, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = transactions[transactionID] else {
            preconditionFailure("Cannot late reject non-existent transaction: \(transactionID)")
        }
        guard existing.status == .completed else {
            preconditionFailure("Precondition failed: transaction must be completed before lateReject")
        }

        let updated = Transaction(
            id: existing.id,
            fromUsername: existing.fromUsername,
            toUsername: existing.toUsername,
            amountCents: existing.amountCents,
            description: existing.description,
            status: .rejected,
            rejectionReason: reason,
            idempotencyKey: existing.idempotencyKey
        )
        transactions[transactionID] = updated

        if creditedToRecipientTxIDs.contains(existing.id) {
            balances[existing.toUsername, default: 100000] -= existing.amountCents
        }
        balances[existing.fromUsername, default: 100000] += existing.amountCents

        changeLog.append((seq: nextSeq, txId: transactionID))
        nextSeq += 1
        persistStateLocked()
    }

    // MARK: - Admin Commands

    /// Flips all pending transactions to completed and credits counterparties.
    public func settlePending() {
        lock.lock()
        defer { lock.unlock() }
        for (id, tx) in transactions where tx.status == .pending {
            let completed = Transaction(
                id: tx.id,
                fromUsername: tx.fromUsername,
                toUsername: tx.toUsername,
                amountCents: tx.amountCents,
                description: tx.description,
                status: .completed,
                rejectionReason: tx.rejectionReason,
                idempotencyKey: tx.idempotencyKey
            )
            transactions[id] = completed

            // If recipient has not been credited yet (e.g. normal outgoing/incoming payment), credit upon settle
            if !creditedToRecipientTxIDs.contains(id) {
                balances[tx.toUsername, default: 100000] += tx.amountCents
                creditedToRecipientTxIDs.insert(id)
            }

            changeLog.append((seq: nextSeq, txId: id))
            nextSeq += 1
        }
        persistStateLocked()
    }

    /// Someone else pays Eva. In normal mode, debits sender immediately and credits recipient upon settle.
    /// In balance-ahead mode (holdIncomingFromFeed == true), credits recipient immediately and records it
    /// so subsequent settlement does not double credit.
    public func pay(from: String, toEva: String = "eva", amountCents: Int, description: String) {
        lock.lock()
        defer { lock.unlock() }

        txIdCounter += 1
        let txId = String(format: "txn_%08x", txIdCounter)

        balances[from, default: 100000] -= amountCents
        if holdIncomingFromFeed {
            balances[toEva, default: 100000] += amountCents
            creditedToRecipientTxIDs.insert(txId)
        }

        let tx = Transaction(
            id: txId,
            fromUsername: from,
            toUsername: toEva,
            amountCents: amountCents,
            description: description,
            status: .pending,
            rejectionReason: nil,
            idempotencyKey: nil
        )
        transactions[txId] = tx

        if holdIncomingFromFeed {
            heldTxIDs.append(txId)
        } else {
            changeLog.append((seq: nextSeq, txId: txId))
            nextSeq += 1
        }
        persistStateLocked()
    }

    // MARK: - Test Staging Synchronization

    /// Holds the next POST /v1/payments in-flight until releaseGate() is called.
    public func gateNextPayment() {
        lock.lock()
        defer { lock.unlock() }
        gateNextPaymentArmed = true
    }

    /// Releases the gated payment.
    public func releaseGate() {
        lock.lock()
        let continuation = gateReleaseContinuation
        gateReleaseContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    /// Asynchronously waits until the next POST reaches the gate.
    public func waitUntilGateReached() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if gateReachedContinuation == nil {
                gateReachedContinuation = continuation
            } else {
                continuation.resume()
            }
            lock.unlock()
        }
    }

    /// The next POST never completes and touches no state, staging app kill before network.
    public func hangNextPaymentBeforeBank() {
        lock.lock()
        defer { lock.unlock() }
        hangNextPaymentArmed = true
    }

    /// Asynchronously waits until the hanging request is intercepted and held.
    public func waitUntilHangReached() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hangingContinuation != nil {
                lock.unlock()
                continuation.resume()
                return
            }
            hangReachedContinuation = continuation
            lock.unlock()
        }
    }

    /// Resumes any hanging continuation to allow clean task teardown.
    public func resumeHanging() {
        cancelHanging()
    }

    /// Injects a hook called immediately after the bank creates a payment in memory (for crash staging).
    public func setOnPaymentCreatedHook(_ hook: (@Sendable () -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        onPaymentCreatedHook = hook
    }

    // MARK: - Inspection API

    public func balance(of username: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return balances[username.lowercased(), default: 100000]
    }

    public func transactions(involving username: String) -> [Transaction] {
        lock.lock()
        defer { lock.unlock() }
        let target = username.lowercased()
        return transactions.values.filter {
            $0.fromUsername.lowercased() == target || $0.toUsername.lowercased() == target
        }
    }

    public func transactionCount(from username: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let target = username.lowercased()
        return transactions.values.filter { $0.fromUsername.lowercased() == target }.count
    }

    public var paymentRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _paymentRequestCount
    }

    public var requestLog: [BankRequestLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return _requestLog
    }

    // MARK: - Reset

    /// Clears all bank state in memory and deletes the persistence file if storageURL is set.
    public func resetData() {
        lock.lock()
        defer { lock.unlock() }
        balances = [
            "eva": 100000,
            "alex": 100000,
            "mila": 100000,
            "noor": 100000
        ]
        transactions.removeAll()
        changeLog.removeAll()
        nextSeq = 1
        idempotencyMap.removeAll()
        _paymentRequestCount = 0
        _requestLog.removeAll()
        txIdCounter = 0
        lostAnswerArmed = false
        isUnreachable = false
        busyScript.removeAll()
        repeatedEntriesMode = nil
        deliveredTxIDs.removeAll()
        holdIncomingFromFeed = false
        heldTxIDs.removeAll()
        creditedToRecipientTxIDs.removeAll()
        if let storageURL {
            try? FileManager.default.removeItem(at: storageURL)
        }
    }

    // MARK: - Internal HTTP Dispatch

    private enum RequestDisposition {
        case unreachable
        case busy(BusyResponse)
        case hang
        case gate(continuationToResume: CheckedContinuation<Void, Never>?)
        case proceed
    }

    private func checkRequestDisposition(method: String, path: String) -> RequestDisposition {
        lock.lock()
        defer { lock.unlock() }

        if isUnreachable {
            return .unreachable
        }
        if !busyScript.isEmpty {
            return .busy(busyScript.removeFirst())
        }
        if method == "POST" && path == "/v1/payments" && hangNextPaymentArmed {
            hangNextPaymentArmed = false
            return .hang
        }
        if method == "POST" && path == "/v1/payments" && gateNextPaymentArmed {
            gateNextPaymentArmed = false
            let reached = gateReachedContinuation
            gateReachedContinuation = nil
            return .gate(continuationToResume: reached)
        }
        return .proceed
    }

    private func registerHangingContinuation(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        hangingContinuation = cont
        let reached = hangReachedContinuation
        hangReachedContinuation = nil
        lock.unlock()
        reached?.resume()
    }

    private func registerGateReleaseContinuation(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        gateReleaseContinuation = cont
    }

    fileprivate func handle(request: URLRequest, client: URLProtocolClient, protocolInstance: URLProtocol) async {
        let method = request.httpMethod?.uppercased() ?? "GET"
        let path = request.url?.path ?? ""

        let disposition = checkRequestDisposition(method: method, path: path)
        switch disposition {
        case .unreachable:
            client.urlProtocol(protocolInstance, didFailWithError: URLError(.notConnectedToInternet))
            return
        case .busy(let busy):
            respondBusy(busy, request: request, client: client, protocolInstance: protocolInstance)
            return
        case .hang:
            await withCheckedContinuation { cont in
                registerHangingContinuation(cont)
            }
            return
        case .gate(let reachedContinuation):
            reachedContinuation?.resume()
            await withCheckedContinuation { releaseCont in
                registerGateReleaseContinuation(releaseCont)
            }
        case .proceed:
            break
        }

        if method == "GET" && path == "/v1/transactions" {
            handleFeed(request: request, client: client, protocolInstance: protocolInstance)
        } else if method == "POST" && path == "/v1/payments" {
            handlePayment(request: request, client: client, protocolInstance: protocolInstance)
        } else {
            respondJSON(status: 404, body: ["error": "Not found"], request: request, client: client, protocolInstance: protocolInstance)
        }
    }

    private func handleFeed(request: URLRequest, client: URLProtocolClient, protocolInstance: URLProtocol) {
        lock.lock()

        var cursorValue: Int? = nil
        if let query = request.url?.query {
            let items = query.components(separatedBy: "&")
            for item in items {
                let pair = item.components(separatedBy: "=")
                if pair.first == "cursor", pair.count == 2 {
                    cursorValue = Int(pair[1])
                }
            }
        }

        let minSeq = cursorValue ?? 0
        let heldSet = Set(heldTxIDs)

        // Filter change log for items strictly greater than cursor
        var relevantTxIDs: [String] = []
        var seenTxIDs = Set<String>()
        var latestSeq: Int = minSeq

        for entry in changeLog where entry.seq > minSeq {
            latestSeq = max(latestSeq, entry.seq)
            if !heldSet.contains(entry.txId) {
                if !seenTxIDs.contains(entry.txId) {
                    seenTxIDs.insert(entry.txId)
                    relevantTxIDs.append(entry.txId)
                }
            }
        }

        var feedTransactions: [Transaction] = []

        if let mode = repeatedEntriesMode {
            repeatedEntriesMode = nil
            switch mode {
            case .duplicateWithinPage:
                for id in relevantTxIDs {
                    if let tx = transactions[id] {
                        feedTransactions.append(tx)
                        feedTransactions.append(tx)
                    }
                }
            case .resendPreviouslyDelivered:
                // Include newly relevant
                for id in relevantTxIDs {
                    if let tx = transactions[id] {
                        feedTransactions.append(tx)
                    }
                }
                // Also include previously delivered
                for id in deliveredTxIDs {
                    if let tx = transactions[id], !relevantTxIDs.contains(id) {
                        feedTransactions.append(tx)
                    }
                }
            }
        } else {
            for id in relevantTxIDs {
                if let tx = transactions[id] {
                    feedTransactions.append(tx)
                }
            }
        }

        // Track delivered
        for tx in feedTransactions {
            deliveredTxIDs.insert(tx.id)
        }
        persistStateLocked()

        let evaBalance = balances["eva", default: 100000]
        let response = FeedResponse(
            transactions: feedTransactions,
            cursor: latestSeq > 0 ? latestSeq : nil,
            balanceCents: evaBalance
        )

        _requestLog.append(BankRequestLogEntry(method: "GET", path: "/v1/transactions", idempotencyKey: nil, statusCode: 200))
        lock.unlock()

        respondEncodable(status: 200, value: response, request: request, client: client, protocolInstance: protocolInstance)
    }

    private func handlePayment(request: URLRequest, client: URLProtocolClient, protocolInstance: URLProtocol) {
        let cachedBody = URLProtocol.property(forKey: FakeBankURLProtocol.bodyKey, in: request) as? Data
        guard let bodyData = request.httpBody ?? cachedBody ?? readHttpBodyStream(request: request) else {
            respondError(status: 400, code: "invalid_request", message: "Missing request body", request: request, client: client, protocolInstance: protocolInstance)
            return
        }

        let decodedRequest: PaymentRequest
        do {
            decodedRequest = try JSONDecoder().decode(PaymentRequest.self, from: bodyData)
        } catch {
            respondError(status: 400, code: "invalid_request", message: "Malformed JSON body", request: request, client: client, protocolInstance: protocolInstance)
            return
        }

        lock.lock()
        _paymentRequestCount += 1

        let sender = "eva"
        let key = decodedRequest.idempotencyKey
        let toUser = decodedRequest.toUsername.lowercased()
        let amount = decodedRequest.amountCents

        // 1. Replay by (eva, key)
        if let existingTxId = idempotencyMap[sender]?[key], let originalTx = transactions[existingTxId] {
            let replayedResponse = PaymentResponse(transaction: originalTx, replayed: true)
            let isLost = lostAnswerArmed
            if isLost { lostAnswerArmed = false }
            _requestLog.append(BankRequestLogEntry(method: "POST", path: "/v1/payments", idempotencyKey: key, statusCode: 200))
            lock.unlock()

            if isLost {
                client.urlProtocol(protocolInstance, didFailWithError: URLError(.networkConnectionLost))
            } else {
                respondEncodable(status: 200, value: replayedResponse, request: request, client: client, protocolInstance: protocolInstance)
            }
            return
        }

        // 2. unknown_user 404
        if balances[toUser] == nil {
            _requestLog.append(BankRequestLogEntry(method: "POST", path: "/v1/payments", idempotencyKey: key, statusCode: 404))
            lock.unlock()
            respondError(status: 404, code: "unknown_user", message: "User not found", request: request, client: client, protocolInstance: protocolInstance)
            return
        }

        // 3. invalid_amount 422
        if amount <= 0 {
            _requestLog.append(BankRequestLogEntry(method: "POST", path: "/v1/payments", idempotencyKey: key, statusCode: 422))
            lock.unlock()
            respondError(status: 422, code: "invalid_amount", message: "Amount must be greater than zero", request: request, client: client, protocolInstance: protocolInstance)
            return
        }

        // 4. self_payment 422
        if toUser == sender {
            _requestLog.append(BankRequestLogEntry(method: "POST", path: "/v1/payments", idempotencyKey: key, statusCode: 422))
            lock.unlock()
            respondError(status: 422, code: "self_payment", message: "Cannot send payment to yourself", request: request, client: client, protocolInstance: protocolInstance)
            return
        }

        // 5. insufficient_funds 422
        let currentEvaBalance = balances[sender, default: 100000]
        if currentEvaBalance < amount {
            _requestLog.append(BankRequestLogEntry(method: "POST", path: "/v1/payments", idempotencyKey: key, statusCode: 422))
            lock.unlock()
            respondError(status: 422, code: "insufficient_funds", message: "Insufficient funds", request: request, client: client, protocolInstance: protocolInstance)
            return
        }

        // 6. Create pending tx, debit eva at once, append change
        txIdCounter += 1
        let newTxId = String(format: "txn_%08x", txIdCounter)
        balances[sender] = currentEvaBalance - amount

        let newTx = Transaction(
            id: newTxId,
            fromUsername: sender,
            toUsername: toUser,
            amountCents: amount,
            description: decodedRequest.description,
            status: .pending,
            rejectionReason: nil,
            idempotencyKey: key
        )
        transactions[newTxId] = newTx

        if !key.isEmpty {
            if idempotencyMap[sender] == nil {
                idempotencyMap[sender] = [:]
            }
            idempotencyMap[sender]?[key] = newTxId
        }

        changeLog.append((seq: nextSeq, txId: newTxId))
        nextSeq += 1
        persistStateLocked()

        let isLost = lostAnswerArmed
        if isLost { lostAnswerArmed = false }
        _requestLog.append(BankRequestLogEntry(method: "POST", path: "/v1/payments", idempotencyKey: key, statusCode: 201))
        let hook = onPaymentCreatedHook
        lock.unlock()

        hook?()

        if isLost {
            client.urlProtocol(protocolInstance, didFailWithError: URLError(.networkConnectionLost))
        } else {
            let paymentResponse = PaymentResponse(transaction: newTx, replayed: false)
            respondEncodable(status: 201, value: paymentResponse, request: request, client: client, protocolInstance: protocolInstance)
        }
    }

    private func respondBusy(_ busy: BusyResponse, request: URLRequest, client: URLProtocolClient, protocolInstance: URLProtocol) {
        let statusCode: Int
        var headers: [String: String] = ["Content-Type": "application/json"]

        switch busy {
        case .serviceUnavailable:
            statusCode = 503
        case .tooManyRequests(let retryAfterSeconds):
            statusCode = 429
            headers["Retry-After"] = String(retryAfterSeconds)
        }

        let method = request.httpMethod?.uppercased() ?? "GET"
        let path = request.url?.path ?? ""

        var key: String? = nil
        if method == "POST" && path == "/v1/payments" {
            let cachedBody = URLProtocol.property(forKey: FakeBankURLProtocol.bodyKey, in: request) as? Data
            if let data = request.httpBody ?? cachedBody ?? readHttpBodyStream(request: request),
               let decoded = try? JSONDecoder().decode(PaymentRequest.self, from: data) {
                key = decoded.idempotencyKey
            }
        }

        lock.lock()
        if method == "POST" && path == "/v1/payments" {
            _paymentRequestCount += 1
        }
        _requestLog.append(BankRequestLogEntry(method: method, path: path, idempotencyKey: key, statusCode: statusCode))
        lock.unlock()

        let body = ["error": ["code": "bank_busy", "message": "The bank is currently busy"]]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()

        guard let url = request.url,
              let httpResponse = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client.urlProtocol(protocolInstance, didFailWithError: URLError(.badServerResponse))
            return
        }

        client.urlProtocol(protocolInstance, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(protocolInstance, didLoad: data)
        client.urlProtocolDidFinishLoading(protocolInstance)
    }

    private func respondError(status: Int, code: String, message: String, request: URLRequest, client: URLProtocolClient, protocolInstance: URLProtocol) {
        let errorBody = BankErrorBody(error: BankErrorBody.Details(code: code, message: message))
        respondEncodable(status: status, value: errorBody, request: request, client: client, protocolInstance: protocolInstance)
    }

    private func respondEncodable<T: Encodable>(status: Int, value: T, request: URLRequest, client: URLProtocolClient, protocolInstance: URLProtocol) {
        let encoder = JSONEncoder()
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            client.urlProtocol(protocolInstance, didFailWithError: error)
            return
        }

        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client.urlProtocol(protocolInstance, didFailWithError: URLError(.badServerResponse))
            return
        }

        client.urlProtocol(protocolInstance, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(protocolInstance, didLoad: data)
        client.urlProtocolDidFinishLoading(protocolInstance)
    }

    private func respondJSON(status: Int, body: [String: Any], request: URLRequest, client: URLProtocolClient, protocolInstance: URLProtocol) {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client.urlProtocol(protocolInstance, didFailWithError: URLError(.badServerResponse))
            return
        }
        client.urlProtocol(protocolInstance, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(protocolInstance, didLoad: data)
        client.urlProtocolDidFinishLoading(protocolInstance)
    }

    private func readHttpBodyStream(request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }

    fileprivate func cancelHanging() {
        lock.lock()
        let cont = hangingContinuation
        hangingContinuation = nil
        lock.unlock()
        cont?.resume()
    }
}

// MARK: - URLProtocol Subclass
nonisolated public final class FakeBankURLProtocol: URLProtocol, @unchecked Sendable {
    public static let bodyKey = "FakeBankHTTPBodyDataKey"
    private var workTask: Task<Void, Never>?

    public override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return FakeBank.bank(for: host) != nil
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            return request
        }
        if let body = request.httpBody {
            URLProtocol.setProperty(body, forKey: bodyKey, in: mutable)
        }
        return mutable as URLRequest
    }

    public override func startLoading() {
        guard let host = request.url?.host, let bank = FakeBank.bank(for: host), let client = self.client else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        workTask = Task {
            await bank.handle(request: self.request, client: client, protocolInstance: self)
        }
    }

    public override func stopLoading() {
        workTask?.cancel()
        if let host = request.url?.host, let bank = FakeBank.bank(for: host) {
            bank.cancelHanging()
        }
    }
}

#if DEBUG
extension FakeBank: BankDebugControls {}
#endif

