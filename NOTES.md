# EvaLedger Architecture & Implementation Notes

Time spent: about 3 hours.
The work was completed using an AI pair programmer, as permitted by the assignment guidelines.

---

## 1. What can go wrong, and what the user sees

| What happens | What the app does | What is on screen while it happens | Proving test |
| :--- | :--- | :--- | :--- |
| **Lost answer**<br>Bank creates payment and debits Eva, but network drops before client receives response (`URLError.networkConnectionLost`). | Classifies outcome as `.ambiguous`. Persists attempt as `.unconfirmed`. Marks `isStale = true`. Never executes blind retry or speculative debit. Waits for feed sync to resolve by `idempotency_key`. | Row badge shows **"Not confirmed"** (never "Pending" or "Completed"). Header shows last known bank balance with **"Possibly out of date"** banner. Send button unlocked. | `Scenario2LostAnswerTests.scenario2LostAnswerRecovery` |
| **Unreachable**<br>Device has no internet (`URLError.notConnectedToInternet`); request never reaches bank. | Classifies outcome as `.definitelyNotSent`. Persists attempt as `.notSent(reason:)`. Marks `isStale = true`. Strictly does **not** queue or auto-send on subsequent syncs. | Row badge shows **"Not sent: No internet connection"** with **"Try again"** and **"Dismiss"** buttons. Header shows last known balance with **"Possibly out of date"** banner. | `Scenario7UnreachableThenBusyTests.scenario7UnreachableThenBusyWithUserRetryFlow` |
| **Busy**<br>Bank responds with 429 (Too Many Requests) or 503 (Service Unavailable). | Runs bounded retry loop (up to 5 attempts) using the **identical** idempotency key. Waits for `Retry-After` seconds or exponential backoff via injected `Sleeper`. If budget exhausted, marks attempt `.notSent("bank busy")`. | Row badge displays **"Sending…"** with form locked while retrying. If budget exhausted, row badge displays **"Not sent: bank busy"** with **"Try again"** and **"Dismiss"** buttons. | `Scenario7UnreachableThenBusyTests.scenario7UnreachableThenBusyWithUserRetryFlow`<br>`busyBudgetExhaustedEndsAsNotSentAndUserRetryAfterwardsSucceeds` |
| **Repeated entries**<br>Bank delivers duplicate transactions within a feed page, or resends previously delivered entries. | Upserts transactions into `LedgerState` by transaction `id` (last occurrence within a page wins). Removes matching attempts by `idempotency_key`. Advances cursor without regression. | Exactly one row per transaction displaying its latest status badge. No duplicate rows. No parallel unresolved attempt rows. Balance matches bank verbatim. | `Scenario3RepeatedEntriesTests.scenario3RepeatedEntriesDeduplicationAndStateFlow` |
| **Balance ahead of the feed**<br>Incoming payment credits Eva immediately in `balance_cents`, but bank holds transaction from feed until later. | Stores `feedPage.balanceCents` verbatim into `bankBalanceCents`. Does not perform speculative arithmetic or raise error. Stores cursor safely; subsequent release delivers incoming transaction. | Header displays new bank balance verbatim ($1,017.08). Row list displays only known transactions without error banner. Upon release, incoming row appears seamlessly. | `Scenario6BalanceAheadOfFeedTests.scenario6BalanceAheadOfFeedFlow` |
| **Late rejection**<br>Bank flips a previously completed payment to `rejected` with reason and refunds Eva. | Feed sync merges updated transaction by `id`, transitioning status to `.rejected(reason:)`. Updates balance verbatim from bank. | Row status updates in-place to **"Rejected: The receiving bank refused it"**. Displayed balance reflects refund verbatim. Original outgoing amount remains visible for accounting history. | `Scenario5LateRejectionTests.scenario5LateRejectionFlow` |
| **App killed**<br>Process killed at any instant: mid-flight before bank, during lost answer, or immediately after 201 response. | Write-ahead logging persisted attempt as `.sending` before network dispatch. On relaunch, `recoverOnLaunch()` safely converts orphaned `.sending` attempts to `.unconfirmed` without network calls. Feed sync resolves by idempotency key or marks `.notSent`. | On launch, row is immediately visible from disk as **"Not confirmed"**. Feed sync transitions row to actual bank state or **"Not sent"** with retry capability. App never auto-POSTs on launch. | `Scenario4KilledMidFlightTests.testAKilledBeforeRequestReachesBank`<br>`testBLostAnswerAndKilledBeforeAppReacts`<br>`testCKilledImmediatelyAfter201BeforeResponseProcessed` |

### Decisions & Assumptions
- **Single Source of Truth**: All ledger data lives in a single, versioned `LedgerState` Codable JSON file written atomically. The UI renders a pure projection (`LedgerProjection`) of this state; no view-layer models or parallel arrays exist.
- **PaymentAttempt Lifecycle**: Created and assigned a unique UUID and idempotency key on tap. Stored on disk as `.sending` -> `.unconfirmed` | `.notSent` | `.failed`. Atomically deleted the moment a transaction carrying the same idempotency key arrives from the bank.
- **Write-Ahead Logging**: The attempt is persisted to disk in `.sending` state before any network request is initiated. An unexpected termination always leaves a recoverable record on disk.
- **Feed Reconciliation by Idempotency Key**: The app never auto-POSTs upon restart or sync. Instead, reconciliation is read-only via GET feed. The bank attaches `idempotency_key` to transactions; when a key matches an in-flight or unconfirmed attempt, the attempt is safely resolved.
- **`notSent` is Best-Effort & Same-Key Retry is Safety Net**: When an offline error occurs or a sync finds no transaction, the attempt is marked `.notSent`. If a network packet had reached the bank despite client-side error, user retry with the *same* idempotency key guarantees the bank returns HTTP 200 replayed rather than creating a duplicate payment.
- **Never Sum for Balance**: The app never computes balance by summing transaction rows or subtracting pending attempts. The bank's `balance_cents` is the sole source of truth and is rendered verbatim.
- **Immediate Incoming Credits in FakeBank**: Incoming transfers are already authorized by the sending institution and credit Eva's balance immediately upon arrival.
- **"Eva sends again" in Scenario 7**: Modeled as the user pressing "Try again" on the `.notSent` row, reusing the attempt ID and persisted idempotency key.
- **No Auto-Sync After Send in Core Engine**: The engine has zero timers and does not trigger side-effect syncs, keeping all tests completely deterministic. The app layer (`LedgerViewModel`) invokes sync following send completion and manages polling.
- **Scenario 1 Bank Gate Invariant**: While a payment is held at the bank gate prior to bank processing, the bank holds exactly 0 transactions and Eva retains her full balance.

---

## 2. The prompt that got you furthest

Prompt 1 (verbatim from `PROMPTS.md`):

```markdown
## Prompt 1: Plan (no code, approval gate)

Read AGENTS.md fully. Do NOT write production code yet.

Produce a plan containing:
1. The proposed file/folder layout (inside the existing Xcode project's synchronized folders): App/, Core/Models, Core/Networking, Core/Persistence, Core/Ledger, Core/Payments, Fake/FakeBank.swift (single file), UI/, and the Tests folder layout.
2. The exact public API (signatures only) of: Money, Transaction, PaymentAttempt, LedgerState, BankClient, Persistence, Sleeper, LedgerStore (actor), PaymentEngine (send / retry / dismiss / sync / recoverOnLaunch), the projection (TransactionRow, RowStatus, BalanceDisplay), and FakeBank's switch/inspection API.
3. A state-transition table for PaymentAttempt covering: tap, 201, 200 replayed, 404/422, 429/503 retry loop, notConnectedToInternet, networkConnectionLost, process kill at each point (before persist, after persist before request, after bank created but before response handled), relaunch, successful sync with/without key match, user retry, dismiss.
4. For each of the 7 scenarios (scenario 4 has two tests): the exact assertions you propose (rows, row states, displayed balance, isStale, bank-side transaction count, count of POST requests that reached the bank). Flag every place where you had to make an assumption about the spec.
5. A list of risks and how the design addresses them.

Then stop and wait for my approval.
```

**Why this prompt was selected:**
Prompt 1 produced `PLAN.md` and established the architectural invariants before any production code was written. It forced an exhaustive `PaymentAttempt` state-transition matrix up front—ensuring write-ahead persistence, launch recovery of orphaned `.sending` attempts to `.unconfirmed` without network I/O, and read-only feed reconciliation matching by idempotency key. It also locked in the public API signatures and exact scenario assertions across all 7 scenarios. While later prompts still required adjustments and enhancements to `FakeBank`, `BankClient`, `BusyRetryPolicy`, and `PaymentEngine`, having the core types, write-ahead sequence, and scenario test contracts agreed upon prevented foundational drift.

---

## 3. Where the AI was wrong

- **What was produced:** When implementing `PaymentEngine.swift` in Prompt 6 (`d5c18d4`), the disk persistence calls (`try await store.mutate { draft in draft.updateAttemptState(...) }`) in the `.definitelyNotSent`, `.rejectedFinal`, and `.busy` branches of `applyPaymentOutcome` were wrapped in an empty `catch {}` block.
- **Why it was wrong:** `LedgerStore.mutate` only updates in-memory state (`self.state = draft`) if `persistence.save(draft)` succeeds. If disk persistence failed (e.g. disk full, permission issue, or frozen persistence), the empty `catch {}` silently swallowed the error. As a result, both the disk file and in-memory `LedgerStore` remained in state `.sending`, while `applyPaymentOutcome` returned `.notSent` or `.failed` to the caller. For the user, the UI snapshot read `.sending` from `store`, keeping the Send button permanently disabled (`!isSending`) and displaying a perpetual "Sending…" spinner, freezing the payment form ("lies-to-user / UI freeze").
- **Who noticed:** Found during the Prompt 14 hostile review run while auditing for swallowed errors (`catch {}`) and memory/disk state divergence.
- **What was done:** Fixed in commit `e3c8667` (`Fix: Prevent desynchronized state when attempt persistence fails`). If persisting a terminal state fails, the on-disk state remains `.sending` (which recovers to `.unconfirmed` on relaunch). Rather than returning a false terminal state, the outcome is honestly reported as `.unconfirmed`, keeping the UI in sync with actual disk reality.

---

## 4. What's next

If given another two hours, the following additions would be prioritized:
1. **Shared Contract Tests with Staging**: Run `FakeBankContractTests` against a real bank staging environment over HTTPS to ensure fake bank fidelity with real backend behavior.
2. **XCUITest Coverage**: End-to-end UI tests covering the happy path, form validation, and simulated process termination / relaunch.
3. **Background Refresh**: Integration with `BGAppRefreshTask` and Apple Push Notification service (APNs) for real-time feed synchronization when the app is suspended.
4. **Automated Schema Migration Tests**: Explicit unit test suites validating smooth schema migrations across multiple versions (e.g., v1 -> v2) with backward compatibility.
5. **Structured Logging (`OSLog`)**: Replace silent catches with Apple's unified logging system, tagging subsystems and privacy-redacted categories (`OSLogPrivacy.public` vs `.private`) without logging sensitive PII.
6. **Detailed Error Handling for Unknown 4xx**: Parse and display server-provided error codes beyond standard 404/422/429 status codes.
7. **Transaction Audit Trail**: Detailed view showing attempt creation timestamp, raw idempotency key, bank transaction ID, and full change-log history.
8. **Graceful Storage Open Failure**: Storage initialization in `AppEnvironment` currently uses `fatalError` if disk storage fails to open. A proper production solution needs a visible error state rather than an unhandled crash or a silent fallback to an empty in-memory store (which would hide unconfirmed payments).

---

## Bonus: What would change with 50,000 transactions

Handling 50,000 transactions at banking-grade reliability requires architectural scaling across networking, persistence, and rendering:
1. **Paginated Feed Sync**: The bank endpoint must support pagination (`GET /v1/transactions?cursor=...&limit=100`) with a `has_more` flag to avoid massive single-payload HTTP responses.
2. **SQLite / Indexed Database**: Rewriting a monolithic 50,000-item JSON file on every sync (~15-25 MB) would cause disk I/O thrashing and high latency. Moving to SQLite (via GRDB or raw C SQLite) with indexing on `id`, `idempotency_key`, `first_seen_order`, and `status` provides O(1) indexed upserts and incremental writes.
3. **Append-Only Change Log + Compaction**: Store feed changes in an append-only log table and maintain a materialized snapshot table for fast reads.
4. **Windowed / Incremental Projection**: The current pure projection computes all rows in memory. With 50,000 rows, projection must be windowed (e.g. projecting only the latest 50 rows or the current scroll viewport).
5. **Virtualization and Diffable UI**: SwiftUI `List` / `LazyVStack` backed by an `AsyncSequence` or paginated data source so only visible rows are hydrated into memory.
6. **Background Offloading**: Decoding, indexing, and SQLite transactions executed on background actor threads; the UI thread receives only immutable view state slices.
7. **Memory Profile**: Memory footprint kept bounded under ~30 MB regardless of total transaction count by not retaining 50,000 full transaction records in active RAM.
