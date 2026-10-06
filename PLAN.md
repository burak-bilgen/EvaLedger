# EvaLedger: Architecture & Implementation Plan

> Generated for Prompt 1 of `PROMPTS.md`. Per autonomous instructions, if any point here contradicts `AGENTS.md`, `AGENTS.md` wins.

## 1. File & Folder Layout

All files live inside the Xcode synchronized folders `EvaLedger/` (app target) and `EvaLedgerTests/` (test target).

```text
EvaLedger/
├── App/
│   ├── EvaLedgerApp.swift                 # App entry point
│   └── AppEnvironment.swift               # Composition root (wiring FakeBank, Store, Engine)
├── Core/
│   ├── Models/
│   │   ├── Money.swift                    # Money formatting & integer cents parsing
│   │   ├── Transaction.swift              # Transaction, TransactionStatus, Feed & Bank DTOs
│   │   └── PaymentAttempt.swift           # PaymentAttempt, AttemptState (explicit Codable)
│   ├── Networking/
│   │   ├── BankClient.swift               # BankClient protocol, PaymentOutcome, URLSessionBankClient
│   │   └── BusyRetryPolicy.swift          # Busy retry loop, Sleeper protocol, RealSleeper
│   ├── Persistence/
│   │   ├── Persistence.swift              # Persistence protocol, PersistenceError
│   │   └── FileLedgerPersistence.swift    # Atomic Codable JSON persistence & corrupt backups
│   ├── Ledger/
│   │   ├── LedgerState.swift              # Pure persisted state (schema v1) & pure mutations
│   │   ├── LedgerStore.swift              # Actor owning LedgerState and atomic disk persistence
│   │   └── LedgerProjection.swift         # Pure projection: LedgerState -> [TransactionRow], BalanceDisplay
│   └── Payments/
│       ├── PaymentEngine.swift            # Orchestrator actor (send, retry, dismiss, sync, recoverOnLaunch)
│       ├── IDGenerator.swift              # Injectable ID & idempotency key generation
│       └── Clock.swift                    # Injectable Clock (Date)
├── Fake/
│   └── FakeBank.swift                     # Single file: FakeBank class, URLProtocol, switches, inspection
└── UI/
    ├── LedgerViewModel.swift              # Thin @Observable view model projecting state
    ├── LedgerView.swift                   # Main screen: balance header, banner, feed list, send form
    └── DebugPanelView.swift               # #if DEBUG remote control panel for FakeBank

EvaLedgerTests/
├── Harness/
│   ├── AppHarness.swift                   # Test harness wrapping harness lifecycle, kill(), relaunch()
│   ├── TestFixtures.swift                 # Deterministic ID generators, clocks, sample fixtures
│   ├── RecordingSleeper.swift             # Non-sleeping sleeper recording requested durations
│   └── FrozenPersistence.swift            # Persistence wrapper simulating sudden process death
├── Unit/
│   ├── MoneyTests.swift                   # Money formatting and parsing tests
│   ├── TransactionEncodingTests.swift     # Explicit JSON decoding tests, unknown status handling
│   ├── LedgerStateTests.swift             # Pure mutations: feed merge, duplicate id handling, cursor
│   ├── LedgerProjectionTests.swift        # Ordering, sign, attempt deduplication
│   ├── BankClientTests.swift              # Outcome mapping, HTTP status classification, retry loop
│   └── PersistenceTests.swift             # Atomic save/load, corruption backup, schema validation
├── FakeBankTests/
│   └── FakeBankContractTests.swift        # Contract tests against FakeBank via URLSession
└── Scenarios/
    ├── Scenario1NormalPaymentTests.swift  # Scenario 1: Golden path & write-ahead verification
    ├── Scenario2LostAnswerTests.swift     # Scenario 2: URLError.networkConnectionLost & feed resolution
    ├── Scenario3RepeatedEntriesTests.swift# Scenario 3: Feed duplicates and redeliveries
    ├── Scenario4KilledMidFlightTests.swift # Scenario 4: Killed before bank (A), lost answer (B), 201 gap (C)
    ├── Scenario5LateRejectionTests.swift  # Scenario 5: Late rejection & bank refund
    ├── Scenario6BalanceAheadOfFeedTests.swift # Scenario 6: Held incoming transaction & sequence shift
    ├── Scenario7UnreachableThenBusyTests.swift# Scenario 7: Unreachable -> notSent -> user retry -> 429/503 -> 201
    └── LedgerViewModelTests.swift         # Thin ViewModel UI behavior tests
```

---

## 2. Public APIs (Signatures Only)

### Money
```swift
public enum Money {
    public static func format(cents: Int) -> String
    public static func parse(input: String) throws(MoneyParseError) -> Int
}
public enum MoneyParseError: Error, Equatable, Sendable, LocalizedError {
    case empty, nonNumeric, negative, zero, moreThanTwoDecimals, overflow
}
```

### Transaction & DTOs
```swift
public enum TransactionStatus: Codable, Equatable, Sendable {
    case pending, completed, rejected, unknown(String)
}
public struct Transaction: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let fromUsername: String
    public let toUsername: String
    public let amountCents: Int
    public let description: String
    public let status: TransactionStatus
    public let rejectionReason: String?
    public let idempotencyKey: String?
}
public struct FeedResponse: Codable, Equatable, Sendable {
    public let transactions: [Transaction]
    public let cursor: Int?
    public let balanceCents: Int
}
public struct PaymentRequest: Codable, Equatable, Sendable {
    public let toUsername: String
    public let amountCents: Int
    public let description: String
    public let idempotencyKey: String
}
public struct PaymentResponse: Codable, Equatable, Sendable {
    public let transaction: Transaction
    public let replayed: Bool
}
public struct BankErrorBody: Codable, Equatable, Sendable {
    public struct Details: Codable, Equatable, Sendable {
        public let code: String
        public let message: String
    }
    public let error: Details
}
```

### PaymentAttempt
```swift
public enum AttemptState: Codable, Equatable, Sendable {
    case sending
    case unconfirmed
    case notSent(reason: String)
    case failed(code: String, message: String)
}
public struct PaymentAttempt: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let idempotencyKey: String
    public let toUsername: String
    public let amountCents: Int
    public let description: String
    public let createdAt: Date
    public var state: AttemptState
}
```

### LedgerState
```swift
public struct LedgerState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var transactions: [String: Transaction]
    public var firstSeenOrders: [String: Int]
    public var nextOrder: Int
    public var cursor: Int?
    public var bankBalanceCents: Int?
    public var balanceAsOf: Date?
    public var attempts: [PaymentAttempt]

    public mutating func merge(feedPage: FeedResponse, receivedAt: Date)
    public mutating func insertIfAbsent(acceptedTransaction: Transaction, receivedAt: Date)
    public mutating func recordAttempt(_ attempt: PaymentAttempt)
    public mutating func updateAttemptState(id: UUID, state: AttemptState)
    public mutating func removeAttempt(id: UUID)
}
```

### BankClient & Networking
```swift
public enum PaymentOutcome: Equatable, Sendable {
    case accepted(Transaction, replayed: Bool)
    case rejectedFinal(code: String, message: String)
    case busy(retryAfter: TimeInterval?)
    case definitelyNotSent
    case ambiguous(reason: String)
}
public protocol BankClient: Sendable {
    func fetchFeed(cursor: Int?) async throws -> FeedResponse
    func createPayment(_ request: PaymentRequest) async -> PaymentOutcome
}
public final class URLSessionBankClient: BankClient { ... }
```

### Persistence
```swift
public protocol Persistence: Sendable {
    func load() throws -> LedgerState?
    func save(_ state: LedgerState) throws
}
public final class FileLedgerPersistence: Persistence { ... }
public final class FrozenPersistence: Persistence, @unchecked Sendable { ... }
```

### Sleeper & Retry Policy
```swift
public protocol Sleeper: Sendable {
    func sleep(for duration: TimeInterval) async throws
}
public struct RealSleeper: Sleeper { ... }
public final class RecordingSleeper: Sleeper, @unchecked Sendable { ... }
public struct BusyRetryPolicy: Sendable { ... }
```

### LedgerStore (actor)
```swift
public actor LedgerStore {
    public init(persistence: any Persistence, initialState: LedgerState? = nil) throws
    public func snapshot() -> LedgerState
    public func mutate<T>(_ operation: (inout LedgerState) throws -> T) throws -> T
    public func snapshots() -> AsyncStream<LedgerState>
}
```

### PaymentEngine (actor)
```swift
public enum SendResult: Equatable, Sendable {
    case accepted(Transaction, replayed: Bool)
    case unconfirmed(attemptID: UUID)
    case notSent(reason: String)
    case failed(code: String, message: String)
}
public struct EngineSnapshot: Equatable, Sendable {
    public let ledgerState: LedgerState
    public let isStale: Bool
    public let rows: [TransactionRow]
    public let balanceDisplay: BalanceDisplay
}
public actor PaymentEngine {
    public func send(to username: String, amountCents: Int, description: String) async -> SendResult
    public func retry(attemptID: UUID) async -> SendResult
    public func dismiss(attemptID: UUID) async
    public func sync() async
    public func recoverOnLaunch() async
    public func currentSnapshot() -> EngineSnapshot
    public func snapshots() -> AsyncStream<EngineSnapshot>
}
```

### Projection
```swift
public enum RowStatus: Equatable, Sendable {
    case sending, unconfirmed, notSent(reason: String), failed(message: String), pending, completed, rejected(reason: String)
}
public struct TransactionRow: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable { case attempt(UUID), transaction(String) }
    public let id: String
    public let source: Source
    public let counterparty: String
    public let displayAmountCents: Int
    public let description: String
    public let status: RowStatus
    public let isRetryable: Bool
    public let isDismissible: Bool
    public let createdAt: Date?
}
public struct BalanceDisplay: Equatable, Sendable {
    public let formattedAmount: String?
    public let asOf: Date?
    public let isStale: Bool
}
public enum LedgerProjection {
    public static func project(state: LedgerState, isStale: Bool) -> (rows: [TransactionRow], balance: BalanceDisplay)
}
```

### FakeBank
```swift
public final class FakeBank: @unchecked Sendable {
    public init(uniqueHost: String = UUID().uuidString + ".bank.test")
    public var baseURL: URL { get }
    public func makeSession() -> URLSession

    public func armLostAnswer()
    public func setUnreachable(_ unreachable: Bool)
    public func armBusy(_ script: [BusyResponse])
    public func armRepeatedEntries(_ mode: RepeatedEntriesMode)
    public func setHoldIncomingFromFeed(_ hold: Bool)
    public func releaseHeldTransactions()
    public func lateReject(transactionID: String, reason: String)

    public func settlePending()
    public func pay(from: String, toEva: String = "eva", amountCents: Int, description: String)

    public func gateNextPayment()
    public func releaseGate()
    public func waitUntilGateReached() async
    public func hangNextPaymentBeforeBank()

    public func balance(of username: String) -> Int
    public func transactions(involving username: String) -> [Transaction]
    public func transactionCount(from username: String) -> Int
    public var paymentRequestCount: Int { get }
    public var requestLog: [BankRequestLogEntry] { get }
}
```

---

## 3. State-Transition Table for PaymentAttempt

| Initial State | Event | Next State | Disk Mutation | Resolution / Cleanup | Rationale & Invariant |
|---|---|---|---|---|---|
| None | User tap Send | `.sending` | **Yes (Write-ahead)** | No | Persisted before URLSession sends request. Added to `inFlightIDs`. |
| `.sending` | HTTP 201 Created | **Removed** | **Yes** | **Yes (by key)** | Transaction added if absent; attempt deleted in same atomic write. |
| `.sending` | HTTP 200 Replayed | **Removed** | **Yes** | **Yes (by key)** | Original transaction matches key; attempt deleted. |
| `.sending` | HTTP 404 / 422 | `.failed(code,msg)`| **Yes** | No | Bank rejected conclusively. User can only dismiss. |
| `.sending` | HTTP 429/503 (tries < 5) | `.sending` | No (in-memory retry) | No | Exponential backoff / Retry-After via Sleeper. Same key used. |
| `.sending` | HTTP 429/503 (exhausted) | `.notSent("bank busy")` | **Yes** | No | Retry budget exhausted without bank accepting. |
| `.sending` | notConnectedToInternet | `.notSent("unreachable")` | **Yes** | No | Definitively never reached bank. |
| `.sending` | networkConnectionLost / timeout | `.unconfirmed` | **Yes** | No | Ambiguous transport; money may have moved. |
| None | Killed before persist | None | None | N/A | Clean disk state. |
| `.sending` | Killed before bank call | `.sending` on disk | None | No | Orphaned on launch -> `.unconfirmed`. |
| `.sending` | Killed after bank debit, before response | `.sending` on disk | None | No | Orphaned on launch -> `.unconfirmed`. |
| `.sending` | App relaunch | `.unconfirmed` | **Yes** | No | Any non-in-flight `.sending` on launch converted to `.unconfirmed`. |
| `.unconfirmed` | Sync with key match | **Removed** | **Yes** | **Yes (by key)** | Feed delivers bank transaction; attempt resolved. |
| `.unconfirmed` | Sync without key match | `.notSent("not confirmed")` | **Yes** | No | Successful feed sync is authoritative; only applied if NOT in flight. |
| `.unconfirmed` | Failed sync | `.unconfirmed` | None | No | Still ambiguous; marked stale. |
| `.notSent` | User taps "Try again" | `.sending` | **Yes** | No | Same attempt ID, same idempotency key. |
| `.notSent` | User taps "Dismiss" | **Removed** | **Yes** | No | User discards attempt. |
| `.failed` | User taps "Dismiss" | **Removed** | **Yes** | No | User discards error. |

---

## 4. Scenarios & Proposed Assertions

1. **Scenario 1 (Normal Payment)**:
   - Initial sync: 0 rows, 100000 cents, isStale false, bank tx = 0, POSTs = 0.
   - Gated POST: 1 row `.sending`, 100000 cents, disk attempt is `.sending`, bank tx = 0, POSTs = 1.
   - Released: 1 row `.pending`, 100000 cents, bank tx = 1, POSTs = 1.
   - Settle + sync: 1 row `.completed`, 97500 cents, isStale false, bank tx = 1, POSTs = 1.
2. **Scenario 2 (Lost Answer)**:
   - Send with armLostAnswer: 1 row `.unconfirmed`, 100000 cents, isStale true, bank tx = 1, POSTs = 1.
   - Recovery sync: 1 row `.pending`, 97500 cents, isStale false, bank tx = 1, POSTs = 1 (no second POST).
   - Settle + sync: 1 row `.completed`, 97500 cents, bank tx = 1, POSTs = 1.
   - Sub-tests: sync while unreachable keeps `.unconfirmed` + isStale true; concurrent sync during in-flight send does not mark in-flight attempt `.notSent`.
3. **Scenario 3 (Repeated Entries)**:
   - Eva pays Alex 2500 (201); Mila pays Eva 1000.
   - Feed with `.duplicateWithinPage`: exactly 2 rows (-2500 pending, +1000 pending), balance 98500 verbatim, bank tx = 1, POSTs = 1.
   - Feed with `.resendPreviouslyDelivered`: exactly 2 rows, balance 98500, bank tx = 1, POSTs = 1.
   - Settle + sync: 2 rows (.completed), balance 98500.
4. **Scenario 4 (Killed Mid-Flight)**:
   - Test A (Killed before bank): hung before bank, disk shows `.sending`, kill(). Relaunch -> 1 row `.unconfirmed`, isStale true, POSTs = 0. Settle + sync -> bank tx = 0, row `.notSent`, balance 100000, POSTs = 0. User retry -> same key, 1 row `.completed`, balance 97500, bank tx = 1, POSTs = 1.
   - Test B (Lost answer + killed): armLostAnswer, freeze on bank receive, kill(). Relaunch -> `.unconfirmed`. Sync -> matches key, 1 row `.pending`, balance 97500, bank tx = 1, POSTs = 1. Settle + sync -> `.completed`.
   - Test C (201 + killed): freeze on 201 before response save, kill(). Relaunch -> `.unconfirmed`. Sync -> 1 row `.pending`, balance 97500, bank tx = 1, POSTs = 1.
5. **Scenario 5 (Late Rejection)**:
   - Eva pays Alex 2500 -> 201, settle + sync -> 1 row `.completed`, balance 97500.
   - Bank late-rejects with reason.
   - Sync: STILL exactly 1 row (updated by id), status `.rejected(reason: "...")`, balance 100000 verbatim, isStale false, bank tx = 1.
   - Non-summation test: arbitrary row mutation does not affect displayed balance.
6. **Scenario 6 (Balance Ahead of Feed)**:
   - Initial sync -> 0 rows, 100000 cents.
   - Noor pays Eva 1708, held from feed.
   - Sync: 0 rows, balance 101708 verbatim, isStale false, bank tx = 1.
   - Release held transactions; sync -> 1 row (`+1708`, `.pending`), balance 101708. Cursor advances cleanly.
7. **Scenario 7 (Unreachable, Then Busy)**:
   - Sync -> 100000 cents.
   - Unreachable on: sync fails (isStale true), Eva sends 2500 -> `.notSent("unreachable")`, balance 100000, bank tx = 0, POSTs = 0.
   - Unreachable off, plain sync: row remains `.notSent`, POSTs = 0, isStale false (never auto-sends).
   - Busy armed (429 with 1s Retry-After, 503). User taps "Try again": exactly 3 requests (429, 503, 201), identical key, Sleeper waited 1s then backoff. Row `.pending`, attempts empty.
   - Settle + sync -> 1 row `.completed`, balance 97500, bank tx = 1.
   - Sub-test: busy budget exhausted after 5 tries -> `.notSent("bank busy")`, bank tx = 0.

---

## 5. Risks & Mitigations

1. **Silent Loss / Double Charge on App Kill**: Write-ahead persistence of `.sending` attempt prior to URLSession request; same-key reuse on retry.
2. **Ambiguous Network Drops**: Mapped to `.unconfirmed`, feed-reconciled by idempotency key.
3. **Double Rows**: Pure projection deduplication by idempotency key and atomic attempt deletion.
4. **Math Desynchronization**: Never compute balance by row summation; bank `balance_cents` is sole authority.
5. **Concurrency Races**: Single actor `LedgerStore` serializes disk mutations; in-memory `inFlightIDs` protects active sends from premature reconciliation.
