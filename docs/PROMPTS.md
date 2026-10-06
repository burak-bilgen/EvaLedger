# EvaLedger: ordered prompts

How to use: the agent must read `AGENTS.md` first (master rules). Then tell it:

> Read AGENTS.md. Now execute Prompt N from PROMPTS.md. Only that prompt. Stop and report when its acceptance criteria are met.

Every prompt ends with "Report green": show the passing `xcodebuild test` output, summarize changes, list assumptions and doubts, then STOP and wait.

---

## Prompt 1: Plan (no code, approval gate)

Read AGENTS.md fully. Do NOT write production code yet.

Produce a plan containing:
1. The proposed file/folder layout (inside the existing Xcode project's synchronized folders): App/, Core/Models, Core/Networking, Core/Persistence, Core/Ledger, Core/Payments, Fake/FakeBank.swift (single file), UI/, and the Tests folder layout.
2. The exact public API (signatures only) of: Money, Transaction, PaymentAttempt, LedgerState, BankClient, Persistence, Sleeper, LedgerStore (actor), PaymentEngine (send / retry / dismiss / sync / recoverOnLaunch), the projection (TransactionRow, RowStatus, BalanceDisplay), and FakeBank's switch/inspection API.
3. A state-transition table for PaymentAttempt covering: tap, 201, 200 replayed, 404/422, 429/503 retry loop, notConnectedToInternet, networkConnectionLost, process kill at each point (before persist, after persist before request, after bank created but before response handled), relaunch, successful sync with/without key match, user retry, dismiss.
4. For each of the 7 scenarios (scenario 4 has two tests): the exact assertions you propose (rows, row states, displayed balance, isStale, bank-side transaction count, count of POST requests that reached the bank). Flag every place where you had to make an assumption about the spec.
5. A list of risks and how the design addresses them.

Then stop and wait for my approval.

---

## Prompt 2: Foundations (models, money, DTOs)

Implement the foundation layer with unit tests. No networking, no persistence yet.

1. `Money`: helpers on Int cents.
   - format: 100000 -> "1,000.00", 1708 -> "17.08", 5 -> "0.05", negative supported. Integer math only, no Double.
   - parse user input: "25", "25.5", "25.50", "25,50" -> cents; reject empty, zero, negative, >2 decimals, non-numeric, overflow. Return a typed result/throw with a user-presentable message.
2. `Transaction` (Codable, Equatable, Sendable): id, fromUsername, toUsername, amountCents, description, status, rejectionReason, idempotencyKey. Use EXPLICIT CodingKeys (snake_case), not a global key strategy. `TransactionStatus` = pending | completed | rejected | unknown(String), decoding unknown values without crashing (unknown is displayed as not confirmed).
3. DTOs: `FeedResponse` (transactions, cursor, balance_cents), `PaymentRequest`, `PaymentResponse` (transaction, replayed), `BankErrorBody` ({"error":{"code","message"}}).
4. `PaymentAttempt` and `AttemptState` (sending, unconfirmed, notSent(reason), failed(code,message)) as Codable with stable, explicit encoding (do not rely on synthesized enum encoding that would break on rename; add a schemaVersion strategy note).
5. `LedgerState` (Codable, schemaVersion = 1) per AGENTS.md section 1, with pure mutating functions (no I/O):
   - `merge(feedPage:)` upserting by id, assigning firstSeenOrder only to new ids, last-occurrence-wins within the page, cursor = max, balance verbatim; resolves attempts by idempotency key.
   - `insertIfAbsent(acceptedTransaction:)` for POST responses; resolves the attempt by key.
   - attempt helpers (add, set state, remove).
6. Projection: pure function `LedgerState -> [TransactionRow]`, `RowStatus` = sending | unconfirmed | notSent(reason) | failed(message) | pending | completed | rejected(reason). Outgoing rows are negative, incoming positive from Eva's perspective. Ordering: unresolved attempts first (newest first), then transactions by firstSeenOrder descending. NEVER derive a balance from rows.

Tests (Swift Testing): money formatting/parsing edge cases; JSON decoding of the exact sample payloads from AGENTS.md; unknown status; merge replaces by id (no duplicates), page with duplicates, re-sent older copies, cursor never goes backwards, attempt resolved by key; projection ordering and sign; the projection never contains two rows for the same transaction+attempt.

Commit in 2-3 logical commits. Report green.

---

## Prompt 3: FakeBank (one file)

Create Fake/FakeBank.swift: ONE file containing the entire fake bank. It must follow the contract exactly and expose a switch per misbehavior. It is a URLProtocol-based HTTP fake; the app never calls it directly.

Design:
- `final class FakeBank: @unchecked Sendable` with all mutable state behind a single NSLock (tests need synchronous access from test code, so NOT an actor).
- Each FakeBank instance gets a UNIQUE host, e.g. https://<uuid>.bank.test, registered in a static lock-protected registry host -> FakeBank. `FakeBankURLProtocol` (a URLProtocol subclass) looks up the bank from request.url.host. This makes parallel tests isolated. `bank.makeSession()` returns a URLSession (ephemeral configuration) whose protocolClasses = [FakeBankURLProtocol.self]. `bank.baseURL` is exposed.
- State: balances for eva/alex/mila/noor (100000 each), transactions keyed by id ("txn_" + 8 hex chars, deterministic generator injectable), an append-only change log [(seq, txId)], per-sender idempotency map, request log (method, path, idempotency key, outcome) for assertions.
- GET /v1/transactions[?cursor=N]: returns, for each change-log entry with seq > cursor (all when no cursor), the transaction's CURRENT state; "cursor" = latest seq; "balance_cents" = eva's balance right now. Held (see switch 5) transactions are excluded.
- POST /v1/payments: validate in this order: replay by (eva, key) -> return 200 + replayed:true + original; unknown_user 404; invalid_amount 422 (<=0 or missing); self_payment 422; insufficient_funds 422. Otherwise create pending tx, debit eva at once, append change, 201 replayed:false. Errors are {"error":{"code","message"}}.
- Settle: `settlePending()` flips every pending tx to completed, credits the recipient (an incoming payment to eva was already credited at once, so only the status flips), appends a change per flip. Never timer-driven.
- Someone pays eva: `pay(from:toEva:amountCents:description:)` creates a pending tx from that user, debits sender, credits eva IMMEDIATELY (balance_cents is 101708 before any settle in scenario 6), appends a change.

Switches (programmatic, deterministic, documented in doc comments):
1. `armLostAnswer()`: the NEXT POST /v1/payments is processed normally (state mutated, change appended), then the protocol fails the request with URLError(.networkConnectionLost). One-shot.
2. `setUnreachable(_:)`: while on, EVERY request fails with URLError(.notConnectedToInternet) and bank state is untouched.
3. `armBusy(_ script: [BusyResponse])` where BusyResponse = .serviceUnavailable | .tooManyRequests(retryAfterSeconds: Int). The next N requests (any path) are answered from the script in order, state untouched; afterwards normal.
4. `armRepeatedEntries(_ mode: RepeatedEntriesMode)`, one-shot for the NEXT feed page: `.duplicateWithinPage` (every tx in the page appears twice) and `.resendPreviouslyDelivered` (also include every transaction already delivered to a client before, with current state).
5. `setHoldIncomingFromFeed(_:)` + `releaseHeldTransactions()`: while on, transactions created by `pay(...)` get credited to the balance but are excluded from the feed. On release they are re-appended to the change log with NEW sequence numbers (so a client whose cursor already moved past still receives them).
6. `lateReject(transactionID:reason:)`: completed -> rejected with rejection_reason, refund eva (and reverse the recipient credit), append change. Precondition: must be completed.

Test-staging helpers (NOT among the six; for killing/in-flight tests):
- `gateNextPayment()`: the next POST is received and recorded but the response is held until `releaseGate()`. Provide `waitUntilGateReached() async` so tests can await "request is in flight" deterministically. No sleeps, no polling with real timeouts.
- `hangNextPaymentBeforeBank()`: the next POST never mutates state and never completes (until the loading is cancelled), to stage "app killed before the request reached the bank".

Inspection (for assertions): `balance(of:)`, `transactions(involving:)`, `transactionCount(from:)`, `paymentRequestCount` (POSTs that were received), `requestLog`.

HTTP details: real HTTPURLResponse with statusCode, headers (Content-Type: application/json, Retry-After as string seconds for 429), JSON bodies via JSONEncoder with explicit keys. Deliver via client callbacks correctly (didReceive, didLoad, didFinishLoading), and implement stopLoading to cancel pending gate/hang work.

Also write `FakeBankContractTests.swift` that hits the fake with a plain URLSession (the fake's own session) and proves every contract rule: first-call feed, cursor semantics, change redelivery on status change, 201 shape, replay 200, each final error, debit-at-once, credit-on-settle, late reject refund, each switch's behavior (lost answer really creates the payment, unreachable leaves state untouched, busy sequence, repeated entries both modes, held transactions and release with a cursor that already advanced).

Commit. Report green.

---

## Prompt 4: BankClient (URLSession, error classification, retry)

Implement the networking layer in Core/Networking. Real URLSession code; the session is injected (tests pass bank.makeSession()).

1. `protocol BankClient: Sendable` with:
   - `func fetchFeed(cursor: Int?) async throws -> FeedResponse` (plain `throws` with a typed error enum, or typed throws if it compiles cleanly under Swift 6; tell me which you picked)
   - `func createPayment(_ request: PaymentRequest) async -> PaymentOutcome`
2. `PaymentOutcome` is an exhaustive enum mapped EXACTLY per AGENTS.md section 5: `.accepted(Transaction, replayed: Bool)`, `.rejectedFinal(code, message)`, `.busy(retryAfter: TimeInterval?)`, `.definitelyNotSent`, `.ambiguous(reason)`. The mapping is a pure function (status code + headers + body + error -> outcome) so it can be unit tested without HTTP.
3. `URLSessionBankClient` implementing it: builds requests with JSON bodies and explicit headers, sets a sane request timeout, decodes with the explicit CodingKeys, and NEVER retries by itself (retry policy lives one layer up).
4. `BusyRetryPolicy` + `Sleeper` protocol (`RealSleeper` uses Task.sleep; `RecordingSleeper` for tests records requested durations and returns immediately). Policy: max 5 total attempts; delay = Retry-After seconds (capped at 30) when given, otherwise exponential backoff 0.5s, 1s, 2s, 4s; deterministic, no jitter. The retry loop re-sends the IDENTICAL request (same idempotency key). Task cancellation must be respected.
5. The feed GET uses the same busy handling (bounded) and surfaces transport failure as an error the caller maps to "stale".

Tests: table-driven outcome mapping (201, 200 replayed, 404, each 422 code, 429 with/without Retry-After, 503, 500, 400 unknown error body, 201 with garbage JSON, notConnectedToInternet, networkConnectionLost, timedOut, cancelled); retry loop with the fake's armBusy([.tooManyRequests(1), .serviceUnavailable]) proving: three requests with the same idempotency key, sleeper recorded 1s then backoff, final success; budget exhaustion returns busy-exhausted without crashing.

Commit. Report green.

---

## Prompt 5: Persistence + LedgerStore actor

Implement persistence and the ledger actor.

1. `protocol Persistence: Sendable { func load() throws -> LedgerState?; func save(_ state: LedgerState) throws }` and `FileLedgerPersistence`: JSON in a given file URL, written with `Data.write(to:options:.atomic)`, creating the directory if needed. If the file is missing return nil. If the file is corrupt, do NOT crash and do NOT silently discard money-relevant data: surface a typed error and keep a `.corrupt` backup copy of the bad file (explain your choice in a comment). Handle unknown future schemaVersion explicitly.
2. `actor LedgerStore`: owns the in-memory `LedgerState` and persists after EVERY mutation (one atomic save per mutation). API: `snapshot()`, a mutation entry point (specific intent methods or `apply(_:)`, whichever is cleaner), and an AsyncStream/observation hook the view model can subscribe to so the UI re-renders from the snapshot. A failed save must not leave memory ahead of disk: either roll back the in-memory mutation or fail loudly (explain which and why).
3. A test helper `FrozenPersistence` wrapping any Persistence: after `freeze()`, all subsequent saves are silently dropped. This exists to simulate process death faithfully: "after the kill instant NOTHING the old objects do may reach disk".

Tests: save/load round trip including attempts in every state; atomicity sanity (load after failed/dropped save returns the previous state); corrupt file handling; unknown schema version; FrozenPersistence semantics; concurrent mutations from many tasks never lose an update.

Commit. Report green.

---

## Prompt 6: PaymentEngine + Scenario 1 + test harness

Implement the app core and scenario 1.

`PaymentEngine` (actor or class backed by LedgerStore; no timers, no UI imports):
- `send(to:amountCents:description:) async -> SendResult`: 1) validate locally (Money rules), 2) generate attempt id + idempotency key via injected IDGenerator, 3) persist the attempt as `.sending` BEFORE any network I/O, 4) mark the attempt id as in-flight in an in-memory set, 5) run the busy-retry loop around createPayment, 6) apply the outcome per AGENTS.md section 5 with one atomic persist, 7) clear in-flight. It never syncs on its own.
- `retry(attemptID:)`: only for `.notSent`; same attempt, same key, state back to `.sending`, same flow as above.
- `dismiss(attemptID:)`: only for `.notSent` and `.failed`.
- `sync() async`: single-flight; fetch feed with the persisted cursor; on success apply `merge(feedPage:)` + balance + cursor in one atomic persist, set isStale=false, then run reconciliation (AGENTS.md section 6: unconfirmed/orphaned attempts with no key match become notSent, but NEVER attempts currently in the in-flight set). On any failure set isStale=true and change nothing else.
- `recoverOnLaunch()`: converts persisted `.sending` attempts that are not in-flight into `.unconfirmed`. It does NOT touch the network (the launch sync does that). There must be no code path where relaunch issues a POST.
- Expose `isStale` and the projection through a snapshot type the UI/tests can read.

Test harness `AppHarness` (in the test target): builds {FakeBank session, URLSessionBankClient, FileLedgerPersistence at a unique temp URL, FrozenPersistence wrapper, RecordingSleeper, deterministic IDGenerator, fixed Clock, LedgerStore, PaymentEngine}. `kill()` freezes persistence and drops every reference; `relaunch()` builds a brand-new harness from the SAME storage file and the SAME FakeBank instance, then calls recoverOnLaunch. This is how "the app is killed" is proven: all in-memory objects thrown away, bank kept, restart from disk only.

Scenario 1 test:
1. Fresh bank, fresh app, initial sync (balance 100000).
2. gateNextPayment(); start send(alex, 2500, "lunch") in a Task; await bank.waitUntilGateReached(). ASSERT: exactly 1 row, state .sending (not confirmed), the attempt is on disk, and what the bank holds at this point (document which and assert it).
3. releaseGate(); await send. ASSERT: still exactly 1 row, state .pending (attempt row and transaction row are the same row), attempts empty, bank holds exactly 1 transaction from eva.
4. bank.settlePending(); engine.sync(). ASSERT: 1 row, .completed, displayed balance 97500, isStale false, bank holds exactly 1 transaction from eva, paymentRequestCount == 1.

Commit in logical steps. Report green and list every assumption.

---

## Prompt 7: Scenario 2 (Lost answer)

Add scenario 2 as a test, test-first. Do not change production code until the test fails for the right reason.

Setup: fresh bank/app. bank.armLostAnswer(). send(alex, 2500, "lunch") -> the bank creates the payment, the app gets URLError.networkConnectionLost.

Required behavior (adjust the engine only if the test shows a gap):
- Immediately after send returns (BEFORE any recovery): exactly 1 row, state .unconfirmed (clearly "not confirmed", never shown as pending/completed), attempt persisted with its idempotency key, bank holds exactly 1 transaction from eva (the payment HAPPENED), paymentRequestCount == 1, displayed balance is still the last known bank balance (do NOT subtract locally).
- Recovery = a normal sync: the feed contains the transaction carrying our idempotency_key -> the attempt is resolved by key, still exactly 1 row, now .pending, balance 97500 from the bank. Assert the engine sent NO second POST (paymentRequestCount still 1).
- bank.settlePending(); sync -> 1 row .completed, balance 97500, bank holds exactly 1.

Extra tests in the same file:
- Recovery sync while the bank is unreachable: the row stays .unconfirmed, isStale true, nothing is declared notSent (we simply don't know yet), a later sync resolves it.
- A sync that runs while the original send is still in flight must not mark it notSent (in-flight guard). Use gateNextPayment for the staging.

Commit. Report green.

---

## Prompt 8: Scenario 3 (Repeated entries)

Add scenario 3 as a test, test-first.

Steps: (1) send 2500 to alex, bank answers 201 (pending); bank.pay(from: mila, amount 1000) to eva. (2) bank.armRepeatedEntries(.duplicateWithinPage); app syncs: the page contains both transactions twice. (3) bank.armRepeatedEntries(.resendPreviouslyDelivered); app syncs: nothing changed at the bank but the page re-sends both. (4) bank.settlePending(); app syncs.

Assert after EACH sync: exactly 2 rows (never 4, never 6), one outgoing -2500 to alex, one incoming +1000 from mila, correct states (pending/pending after steps 2 and 3, completed/completed after step 4), the attempt row is NOT duplicated next to the transaction row, displayed balance equals the bank's balance_cents verbatim (98500 given eva was debited 2500 and credited 1000 at once), bank holds exactly 1 transaction from eva, paymentRequestCount == 1.

Also add a pure unit test: a re-sent OLD copy never reverts a newer state because the bank always re-sends CURRENT state (document the assumption), and a page that contains the same id twice keeps the last occurrence.

Commit. Report green.

---

## Prompt 9: Scenario 4 (Killed mid-flight, two tests plus one)

Add scenario 4 as TWO tests using AppHarness.kill()/relaunch() (all in-memory objects discarded, same FakeBank, restart purely from the on-disk state).

Test A: killed before the request reaches the bank.
- bank.hangNextPaymentBeforeBank(); start send(alex, 2500, "lunch"); await until the request is in flight; ASSERT the persisted disk state already contains the attempt (.sending) (write-ahead proven by reading the file via a fresh FileLedgerPersistence); kill().
- relaunch(): ASSERT the recovered attempt is .unconfirmed (not .sending, not lost), 1 row visible immediately from disk even though the bank is not consulted yet, and NO POST was issued by relaunch (paymentRequestCount == 0).
- bank.settlePending() (nothing to settle); sync. ASSERT: bank holds 0 transactions from eva; the row is .notSent with a clear reason, displayed balance 100000 (bank's), paymentRequestCount == 0 even after the sync (the app did not auto-send). Then call retry(attemptID) as the USER and assert it goes through with the SAME idempotency key (persisted before the kill), ends pending -> completed after settle+sync, bank holds exactly 1.

Test B: lost answer + killed before the app can react.
- bank.armLostAnswer(); stage the kill so that NOTHING the old objects do after the connection error reaches disk (freeze persistence at the moment the bank has created the payment, e.g. from a FakeBank hook or by freezing when the request is received); send; then kill().
- relaunch(): the attempt is .unconfirmed. sync: the feed contains the transaction with our idempotency key -> the attempt resolves, exactly 1 row .pending, balance 97500, bank holds exactly 1, paymentRequestCount == 1 (the app never re-POSTed). settlePending; sync -> 1 row .completed, 97500, bank holds exactly 1.

Add a third test: kill at the dangerous instant right after the bank created the payment on a SUCCESSFUL 201 whose response was never processed: same expectations as B.

Commit. Report green. Also explain in your report why "notSent" after a successful sync is safe, or what residual risk exists (a request still in transit) and how same-key retry covers it.

---

## Prompt 10: Scenario 5 (Late rejection)

Add scenario 5 as a test, test-first.

Steps: (1) send 2500 to alex, 201; settlePending(); app syncs -> .completed, balance 97500. (2) bank.lateReject(transactionID: <that tx>, reason: "The receiving bank refused it"), eva is refunded. (3) app syncs.

Assert after step 1: 1 row .completed, balance 97500. After step 3: STILL exactly 1 row (updated by id, not appended), state .rejected with reason "The receiving bank refused it", displayed balance 100000 taken from the bank's balance_cents (NOT computed by the app), isStale false, bank holds exactly 1 transaction from eva (now rejected), paymentRequestCount == 1.

Also assert in the projection layer that RowStatus.rejected carries the reason, and that nothing in the code sums amounts to produce a balance (add a test that mutates the ledger so rows would sum to something else and the displayed balance still equals the bank balance).

Commit. Report green.

---

## Prompt 11: Scenario 6 (Balance ahead of the feed)

Add scenario 6 as a test, test-first.

Steps: (1) app syncs, balance 100000. (2) bank.setHoldIncomingFromFeed(true); bank.pay(from: noor, amount 1708). (3) app syncs: feed returns no new transactions and balance_cents is 101708. (4) bank.releaseHeldTransactions(); app syncs: the feed delivers noor's payment.

Assert after step 3: 0 rows, displayed balance 101708 (the bank's number, even though our rows sum to 0; we must NOT "correct" it back to 100000 and must not throw/log an error), isStale false, cursor persisted consistently.
Assert at the end: exactly 1 row (incoming +1708 from noor, state per the fake: pending), balance still 101708, cursor advanced past the release (proving the fake re-appended with new sequence numbers and the app's cursor logic did not skip it), a further sync is idempotent (still 1 row, same balance).
Do NOT add any arithmetic to detect the gap between rows and balance.

Commit. Report green.

---

## Prompt 12: Scenario 7 (Unreachable, then busy)

Add scenario 7 as a test, test-first.

Steps: (1) app syncs, balance 100000. (2) bank.setUnreachable(true); app syncs (fails), then Eva sends 2500 to alex (fails with notConnectedToInternet). (3) setUnreachable(false); bank.armBusy([.tooManyRequests(retryAfterSeconds: 1), .serviceUnavailable]). (4) Eva sends again; the app recovers; bank.settlePending(); app syncs.

Decision for step 4 (state it in NOTES later): "Eva sends again" is the USER pressing "Try again" on the notSent row (same attempt, same idempotency key). Add a second small test for the alternative where the user dismisses the notSent row and starts a fresh payment.

Assert after step 2: displayed balance is still 100000 (last known) and isStale == true (UI marker "possibly out of date"); exactly 1 row for the 2500 payment in state .notSent (not .unconfirmed: notConnectedToInternet means the request never reached the bank); bank holds 0 transactions from eva; paymentRequestCount == 0.
Then PROVE must-have 7: switch unreachable off and run a plain sync, assert the payment was NOT sent on its own (paymentRequestCount still 0, row still .notSent, isStale false now because the sync succeeded) BEFORE the user retries.
Assert at the end: the retry made exactly 3 requests that reached the bank (429, 503, 201), all carrying the identical idempotency key; RecordingSleeper recorded a 1-second wait for the 429 and a backoff wait for the 503; final: 1 row .pending then .completed after settle+sync, balance 97500, isStale false, bank holds exactly 1 transaction from eva.
Add: busy budget exhausted (armBusy with 5+ entries) ends as .notSent("bank busy") with the bank holding 0, and a user retry afterwards succeeds.

Commit. Report green.

---

## Prompt 13: Single screen UI + composition root

Now the single plain SwiftUI screen. UI is NOT graded for looks; it IS graded for what it tells the user. Keep the view model thin: it owns no business logic and no state copies; it renders the engine's snapshot (projection) and forwards intents.

Composition root `AppEnvironment`: production wiring uses a process-wide FakeBank (its state lives in memory in the app process, separate from the ledger file in Application Support) via bank.makeSession(). Include a launch argument or init parameter to inject a different environment for previews/tests.

Screen:
- Header: balance formatted from bankBalanceCents ("—" if never synced), "as of <time>", and a clearly visible banner "Possibly out of date" whenever isStale is true.
- Transaction list from the projection with a status badge: Sending… / Not confirmed / Pending / Completed / Rejected (+ reason) / Not sent (+ reason, with "Try again" and "Dismiss" buttons) / Failed (+ bank message, "Dismiss"). Outgoing negative, incoming positive. No row ever looks confirmed unless the bank said completed.
- Send form: recipient picker (alex, mila, noor), amount text field (parsed via Money, inline error), description, Send button. After tapping Send, disable the button (and lock the form) while an attempt is .sending so one tap can never create two payments.
- Refresh: pull-to-refresh + sync at launch (after recoverOnLaunch) + a simple 5-second polling task owned by the app layer (cancellable, paused when the app is not active). The engine has no timers.
- DEBUG-only panel (#if DEBUG): buttons "Settle pending", "Mila pays Eva 10.00", "Noor pays Eva 17.08", controls for each switch: Lost answer (next payment), Unreachable, Busy (429 then 503), Repeated entries (both modes), Hold incoming from feed + Release, Late reject last completed. These call FakeBank directly (the bank's remote control, not the app's data path).
- After a successful or ambiguous send the view model triggers a sync; tests must not depend on that.
- Add 2-3 lightweight view-model tests (send button disabled while sending, error text for invalid amount, banner appears when stale).

Run the app once on the simulator through the golden path and the lost-answer path and tell me what you saw (if you have simulator tooling); otherwise tell me exactly how I should verify manually.

Commit. Report green.

---

## Prompt 14: Hostile code review

Act as a hostile senior iOS reviewer for a bank. Review the whole repo against AGENTS.md and the eight must-haves. Do not praise. For each finding give: severity (data-loss / double-pay / lies-to-user / flaky / style), file+line, why it is wrong, a failing test that proves it, and the fix.

Specifically hunt for:
1. Any path where a POST can be issued without a user tap (launch, sync, polling, retry loops beyond the same tap).
2. Any path where an attempt is not on disk before network I/O.
3. Any place a balance is computed from transactions, or an optimistic local debit.
4. Any place the feed is appended instead of merged by id; any cursor regression; cursor persisted separately from the merged data.
5. Races: sync vs in-flight send; two concurrent syncs; POST response vs feed copy of the same id; relaunch while a Task from the old process still runs (tests only).
6. notSent declared for an in-flight attempt; unconfirmed shown as pending.
7. Retry loops that change the idempotency key, sleep for real in tests, or ignore cancellation.
8. Swift 6 concurrency warnings, @unchecked Sendable misuse outside the fake, force unwraps, silent `try?` swallowing errors that matter.
9. Test quality: assertions that can pass vacuously, tests depending on timing, tests not asserting the bank-side transaction count.

Fix every confirmed finding with a failing test first, one commit per finding (`Fix: ...`). Then give me a final list of known limitations.

---

## Prompt 15: Hardening (flakes, Cmd+U, clean clone)

Hardening pass:
1. Run the whole test suite 10 times, in parallel and serial, and report any flake; fix root causes (no sleeps, no shared statics except the host-keyed registry).
2. Confirm Cmd+U works with nothing else running: no localhost servers, no environment variables, no network entitlement needs.
3. Fresh-clone check: `git clone` the repo into a temp dir, open the project with no setup, build, and run tests via xcodebuild. Report the result.
4. Ensure FakeBank.swift is a single self-contained file and that the app code never references FakeBank outside AppEnvironment and the DEBUG panel.
5. Check the build has zero warnings under strict concurrency.
6. Check .gitignore, no DerivedData/xcuserdata committed, no secrets.
7. Show `git log --oneline` and tell me if any commit message is vague or if history looks squashed; propose nothing that rewrites history.

Commit fixes. Report.

---

## Prompt 16: NOTES.md and README.md

Create NOTES.md (short, plain, specific) with exactly the four sections the assignment requires, plus the bonus. Fill in sections 1, 4 and the bonus. Leave sections 2 and 3 as clearly marked placeholders (`TODO(human)`), because they must contain the human's real experience. Do not read WORKLOG.md to fill them.

Section 1: "What can go wrong, and what the user sees": a table with one row per misbehavior (Lost answer, Unreachable, Busy, Repeated entries, Balance ahead of the feed, Late rejection) plus "App killed". Columns: What happens | What the app does | What is on screen while it happens. Base it on the ACTUAL implemented behavior and name the test that proves each row.
Also add a short "Decisions & assumptions" list: single source of truth, attempt lifecycle, write-ahead, why feed-reconcile by idempotency key instead of blind re-POST, why notSent is a best-effort verdict and same-key retry is the safety net, why we never sum for balance, why incoming payments credit at once in the fake, what "Eva sends again" means in scenario 7, why no auto-sync after send, which scenario-1 bank-side assumption the test makes.
Section 2: "The prompt that got you furthest": placeholder.
Section 3: "Where the AI was wrong": placeholder.
Section 4: "What's next": what I'd do with another two hours (concrete: contract tests shared between the fake and a real-bank staging, UI tests for the golden/kill paths, background refresh, persistence migration tests, structured logging, handling of unknown 4xx codes, user-visible audit trail for a payment).
Bonus: "What would change with 50,000 transactions": cursor pagination from the bank, SQLite/indexed store instead of rewriting one JSON file per sync, append-only change log + compacted snapshot, id-indexed dictionary already O(1) but the projection must be incremental/windowed, diffable list updates, only the last N rows hydrated in the UI, background decoding, sync batching, memory profile.

Also create a short README.md: what it is, how to run, how to test (Cmd+U), architecture overview in 10 lines, file map, and where the fake lives.

Commit.
