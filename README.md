# EvaLedger

EvaLedger is a banking synchronization iOS application designed to demonstrate correct, robust financial synchronization, crash recovery, and failure handling between a mobile client and a banking ledger under adversarial network conditions.

Built with Swift (`SWIFT_VERSION = 5.0` with Xcode 16 approachable concurrency & strict upcoming features enabled), SwiftUI + Observation, iOS 17.0+, and zero third-party dependencies.

---

## How to Run
1. Open `EvaLedger.xcodeproj` in Xcode 16+.
2. Select the **EvaLedger** scheme and an iOS 17+ Simulator (e.g., iPhone 17).
3. Press **Cmd+R** to build and run.
4. (Optional) In `#if DEBUG` builds, tap the top-right ladybug icon to open the **Debug Remote Control** and test bank behaviors (simulate lost connections, bank busy 429/503 errors, duplicate feed entries, late rejections, incoming transfers, and reset data).

---

## How to Test
Run tests in Xcode with **Cmd+U**, or from the terminal:
```bash
xcodebuild test \
  -project EvaLedger.xcodeproj \
  -scheme EvaLedger \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet
```

All 75 tests across 17 suites are implemented purely in **Swift Testing** (`import Testing`, `@Test`, `#expect`) — no XCTest, no external network calls, no localhost servers, and zero wall-clock sleeps. The entire test suite completes deterministically in ~0.1 seconds.

---

## Build Configuration & Xcode 16 Format
- **Deployment Target**: `IPHONEOS_DEPLOYMENT_TARGET = 17.0` (supports iOS 17.0+ devices and simulators).
- **Concurrency & Language Settings**: `SWIFT_VERSION = 5.0` with `SWIFT_APPROACHABLE_CONCURRENCY = YES` and upcoming concurrency flags enabled (`DisableOutwardActorInference`, `InferSendableFromCaptures`, `GlobalActorIsolatedTypesUsability`, `MemberImportVisibility`, `InferIsolatedConformances`, `NonisolatedNonsendingByDefault`). Full Swift 6 mode is not enabled as non-Sendable `(inout LedgerState)` closures passed to `LedgerStore.mutate` trigger data race diagnostics under strict mode.
- **Project Structure**: Uses Xcode 16's modern JSON-based `project.xcproj` format with file-system synchronized folder groups. Clean clones in `/tmp` run with zero configuration and no machine-specific paths.

---

## Architecture Overview (10 lines)
1. **Single Source of Truth**: All app state is held in a single Codable JSON `LedgerState` persisted atomically with versioning.
2. **Pure Projection**: The UI renders a pure projection (`LedgerProjection`) of `LedgerState`; no parallel view-layer state exists.
3. **Write-Ahead Persistence**: Tapping send writes the attempt as `.sending` to disk *before* dispatching any HTTP request.
4. **Crash Recovery**: Orphaned `.sending` attempts are converted to `.unconfirmed` on app launch without network calls.
5. **Feed Reconciliation**: Syncing is read-only; attempts are matched and resolved by `idempotency_key` delivered by the bank feed.
6. **No Speculative Balance**: Balance is taken verbatim from the bank's `balance_cents`; the client never computes balance by summing rows.
7. **Same-Key Retries**: Retrying a `.notSent` payment reuses the original attempt and idempotency key, eliminating duplicate payment risk.
8. **Bounded Backoff**: HTTP 429 and 503 errors trigger bounded retries with `Retry-After` header support using injected `Sleeper`.
9. **Single-Flight Sync**: Concurrent sync requests await the same in-flight task; background feed and send responses interleave safely.
10. **Actor Isolation**: State mutations and persistence writes are serialized within the `PaymentEngine` and `LedgerStore` actors.

---

## File Map
```
EvaLedger/
├── Core/
│   ├── Models/
│   │   ├── Money.swift                   # Cent-based currency formatting and parsing
│   │   ├── Transaction.swift             # Bank transaction models, DTOs, and status enum
│   │   └── PaymentAttempt.swift          # Client-side payment attempt lifecycle and state
│   ├── Ledger/
│   │   ├── LedgerState.swift             # Persisted state container and pure mutations
│   │   ├── LedgerStore.swift             # Actor owning in-memory state and atomic disk persistence
│   │   └── LedgerProjection.swift        # Pure projection mapping LedgerState to UI display rows
│   ├── Networking/
│   │   ├── BankClient.swift              # HTTP URLSessionBankClient and outcome classification
│   │   └── BusyRetryPolicy.swift         # Bounded retry loop with exponential backoff & Sleeper protocol
│   ├── Persistence/
│   │   ├── Persistence.swift             # Persistence protocol definition
│   │   └── FileLedgerPersistence.swift   # Atomic schema-versioned JSON file persistence with backup recovery
│   ├── Engine/
│   │   ├── PaymentEngine.swift           # Actor orchestrating payment creation, retries, and feed sync
│   │   ├── IDGenerator.swift             # IDGenerator protocol and SystemIDGenerator
│   │   └── EngineClock.swift             # EngineClock protocol and SystemClock
│   └── AppEnvironment.swift              # Composition root wiring dependencies
├── Fake/
│   └── FakeBank.swift                    # Single-file fake bank with dynamic URLProtocol routing & persistence
├── UI/
│   ├── LedgerView.swift                  # Single plain SwiftUI screen (Header, Rows, Send Form)
│   ├── LedgerViewModel.swift             # Thin @Observable view model forwarding intents
│   └── DebugPanelView.swift              # Debug control panel to toggle fake bank misbehaviors
└── EvaLedgerApp.swift                     # SwiftUI App entry point

EvaLedgerTests/
├── Unit/                                 # Unit test suites (Money, Transactions, Projection, Persistence, etc.)
├── FakeBankTests/                        # Contract tests verifying FakeBank against the bank specification
├── Harness/                              # Deterministic test doubles (AppHarness, RecordingSleeper, FrozenPersistence)
└── Scenarios/                            # Acceptance tests for Scenarios 1 through 7
```

---

## Where the Fake Lives
The fake bank lives in a single, self-contained file: `EvaLedger/Fake/FakeBank.swift`.
- It maintains its own state (balances, transaction log, idempotency records), completely isolated from client storage. When run in the app, it persists to a separate file (`evaledger_bank.json`) so process restarts do not wipe the bank. In automated tests, it runs in-memory for speed and isolation.
- It intercepts app HTTP requests using a custom `URLProtocol` registered on the app's `URLSession`.
- The app talks to the bank solely through standard HTTP requests (`GET /v1/transactions`, `POST /v1/payments`).
- The app production paths never reference `FakeBank` directly; only the composition root (`AppEnvironment`) and the `#if DEBUG` `DebugPanelView` interact with it for simulator testing and remote control.
