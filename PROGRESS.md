# EvaLedger Progress Log

## Prompt 1: Architecture & Implementation Plan
- What changed: Created PLAN.md covering directory layout, APIs, state machine, scenario assertions, and risk mitigations.
- Assumptions: Aligned exactly with AGENTS.md; repo root realigned so all project assets and documentation are tracked.
- Doubts: None; specifications and invariants are clear and verified.
- Test result: N/A (Approval gate / documentation only).

## Prompt 2: Foundations (Models, Money, DTOs, LedgerState, Projection)
- What changed: Implemented Money with Int cents formatting and parsing, Transaction and bank DTOs with explicit snake_case keys, PaymentAttempt and AttemptState with stable type discrimination, LedgerState pure mutations, and LedgerProjection. Added 20 unit tests across 4 test suites.
- Assumptions: Handled unknown bank transaction statuses without crashing (projected as unconfirmed). Money formatting handles Int.min safely with 64-bit integer arithmetic.
- Doubts: None; pure functions and models are verified by comprehensive unit tests.
- Test result: Green (20 tests passed in 0.017s via Swift Testing).

## Prompt 3: FakeBank (Single file, URLProtocol fake & contract tests)
- What changed: Created Fake/FakeBank.swift with NSLock-protected in-memory bank, dynamic URLProtocol routing, 6 misbehavior switches, and inspection APIs. Created FakeBankContractTests.swift testing all bank behaviors and switches.
- Assumptions: Normal feed pages deduplicate multiple changes for the same transaction within the window by ID unless .duplicateWithinPage is armed.
- Doubts: None; all 11 contract rules and switches passed deterministically via URLSession.
- Test result: Green (31 tests passed in 0.040s across 5 suites).

## Prompt 4: BankClient (URLSession, Error Classification, Retry Policy)
- What changed: Implemented BankClient protocol, URLSessionBankClient with pure mapOutcome function, Sleeper protocol, and BusyRetryPolicy with bounded exponential backoff. Created RecordingSleeper and BankClientTests with exhaustive outcome mapping and retry loop tests.
- Assumptions: Handled undecodable 2xx responses and 5xx (except 503) as ambiguous. Bounded busy retry max attempts is 5, delay capped at 30 seconds.
- Doubts: None; outcome mapping and retry loop verified via FakeBank and unit tests.
- Test result: Green (43 tests passed in 0.044s across 6 suites).

## Prompt 5: Persistence & LedgerStore Actor
- What changed: Implemented FileLedgerPersistence with atomic writes (.atomic + replaceItemAt backup), corrupt file backup recovery, FrozenPersistence test harness, and LedgerStore actor with rollback on persistence failure. Added PersistenceTests with concurrency and round-trip tests.
- Assumptions: When persistence fails, LedgerStore rolls back in-memory state to the previously known good state before rethrowing. Future schema versions throw typed errors.
- Doubts: None; atomic file operations and concurrency guarantees verified by 7 new tests.
- Test result: Green (50 tests passed in 0.051s across 7 suites).

## Prompt 6: PaymentEngine + Scenario 1 + Test Harness
- What changed: Created EngineClock and IDGenerator protocols with deterministic test doubles, implemented PaymentEngine actor with write-ahead persistence, in-flight tracking, single-flight sync, and launch recovery. Created AppHarness with kill/relaunch capabilities and implemented Scenario 1 lifecycle test.
- Assumptions: While held at the bank gate, bank holds 0 transactions and Eva has full initial balance; write-ahead persistence commits the attempt (.sending) to disk before network dispatch.
- Doubts: None; full scenario flow and write-ahead persistence verified.
- Test result: Green (51 tests passed across 8 suites).

## Prompt 7: Scenario 2 (Lost Answer)
- What changed: Added Scenario2LostAnswerTests covering lost answer resulting in unconfirmed status without speculative arithmetic, subsequent feed reconciliation, unconfirmed retention under unreachable bank sync, and the in-flight reconciliation guard. Added armUnreachable and disarmUnreachable to FakeBank.
- Assumptions: When payment network connection is lost, payment has occurred at bank; client remains unconfirmed displaying authoritative previous balance until reconciled by feed.
- Doubts: None; verified that in-flight payments are protected from false notSent transitions during concurrent sync.
- Test result: Green (54 tests passed across 9 suites).

## Prompt 8: Scenario 3 (Repeated Entries)
- What changed: Created Scenario3RepeatedEntriesTests covering duplicate entries within a feed page, re-sent unchanged entries, and status settlement updates. Added pure unit test verifying last-occurrence semantics and current-state preservation.
- Assumptions: The bank always transmits current authoritative state in feed pages; duplicate IDs within one page resolve to the last occurrence.
- Doubts: None; verified that rows and attempts never duplicate across multiple redundant syncs.
- Test result: Green (56 tests passed across 10 suites).

## Prompt 9: Scenario 4 (Killed Mid-Flight)
- What changed: Added Scenario4KilledMidFlightTests with Tests A, B, and C verifying app kill before network, during lost answer, and immediately after 201 response. Enhanced FakeBank with test-staging hooks (waitUntilHangReached, resumeHanging, onPaymentCreatedHook).
- Assumptions: After launch recovery, an unconfirmed attempt with no feed match resolves to notSent; residual in-transit risk is neutralized because user retry reuses the identical persisted idempotency key.
- Doubts: None; crash resilience and restart purely from on-disk state verified across all failure boundaries.
- Test result: Green (59 tests passed across 11 suites).

## Prompt 10: Scenario 5 (Late Rejection)
- What changed: Added Scenario5LateRejectionTests verifying bank late rejections update transaction status in-place by ID, deliver authoritative refunded balances from the feed, and carry the rejection reason. Added projection unit test ensuring row summation is never used to derive balances.
- Assumptions: The bank feed is authoritative for all balance adjustments following late rejections; the app never performs speculative refund calculations.
- Doubts: None; verified in-place transaction replacement and balance projection immunity to arbitrary row changes.
- Test result: Green (61 tests passed across 12 suites).





