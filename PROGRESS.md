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

## Prompt 11: Scenario 6 (Balance Ahead of Feed)
- What changed: Added Scenario6BalanceAheadOfFeedTests verifying that when a bank balance reflects incoming funds ahead of feed delivery, the balance is displayed verbatim without local deduction/adjustment, and subsequent feed releases advance the cursor and resolve rows idempotently.
- Assumptions: The bank balance is authoritative at all times even when feed changes are held; client never calculates row sum deltas or flags false errors.
- Doubts: None; verified sequence re-append delivery and feed catch-up.
- Test result: Green (62 tests passed across 13 suites).

## Prompt 12: Scenario 7 (Unreachable, Then Busy)
- What changed: Added Scenario7UnreachableThenBusyTests covering definitely-not-sent transitions when offline, verification that plain sync never auto-sends failed payments, same-key user retries across busy 429/503 responses with injected Sleeper backoff, dismiss-and-restart flow, and retry budget exhaustion.
- Assumptions: User retry reuses the identical attempt and idempotency key; auto-sending is strictly prohibited and only user action triggers POST.
- Doubts: None; must-have 7 verified.
- Test result: Green (65 tests passed across 14 suites).

## Prompt 13: Single Screen UI + Composition Root
- What changed: Created AppEnvironment composition root, thin @Observable LedgerViewModel, LedgerView with authoritative header, status badges, lock-on-send form, and DebugPanelView for interactive bank controls. Added 3 ViewModel unit tests and verified live simulator launch.
- Assumptions: Send form is disabled during in-flight sends to prevent double-tap submissions; ViewModel triggers sync following send completion while engine remains timerless.
- Doubts: None; tested in simulator and verified all UI requirements.
- Test result: Green (68 tests passed across 15 suites).
## Prompt 14: Hostile Code Review
- What changed: Conducted hostile review across all 9 checklist categories. Eliminated force unwraps and try! from FakeBank and IDGenerator; moved test doubles (DeterministicIDGenerator, FixedClock) out of the production target into tests; added bank transaction count assertions to Scenario 6; hardened PaymentEngine to prevent desynchronized state if attempt persistence fails; added IDGeneratorTests suite.
- Assumptions: Test doubles belong in test targets so production code contains zero @unchecked Sendable outside the isolated FakeBank.
- Doubts: None; all 9 areas audited and verified with green tests and zero compiler warnings.
- Test result: Green (70 tests passed in 0.073s across 16 suites).

## Prompt 15: Hardening (Flakes, Cmd+U, Clean Clone)
- What changed: Verified 10 consecutive full test runs with 0 flakes (70/70 passing across all 16 suites); confirmed zero external service dependencies; executed clean clone test in temp directory verifying build and test pass with zero setup; confirmed FakeBank is self-contained and only referenced by AppEnvironment/DebugPanelView; verified zero Swift 6 strict concurrency warnings; verified git history hygiene and .gitignore.
- Assumptions: Test suite is completely isolated and deterministic with injected Sleeper, in-memory URLProtocol, and file-based persistence.
- Doubts: None; repository is clean, hardened, and verified.
- Test result: Green (10/10 runs passed, 70/70 tests each run in ~0.065s).

## Prompt 16: NOTES.md and README.md
- What changed: Created NOTES.md with Section 1 (detailed misbehavior table and architectural decisions), Section 2 and 3 TODO(human) placeholders, Section 4 (next steps), and Bonus (50,000 transaction scaling analysis). Created README.md with project overview, running instructions, testing instructions, 10-line architecture summary, file map, and FakeBank isolation details.
- Assumptions: Left NOTES.md sections 2 and 3 strictly as TODO(human) placeholders without reading WORKLOG.md.
- Doubts: None; all prompts 1 through 16 successfully completed and committed.
- Test result: Green (70 tests passed in 0.064s across 16 suites).
