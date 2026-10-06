# EvaLedger: iOS take-home assignment (banking sync correctness)

> This file is the master rule set. Read it fully before doing anything in this repo. It stays in the repo on purpose: it is part of how this project was steered.
> The ordered work plan lives in `PROMPTS.md`. The user will tell you which prompt number to execute. Execute ONLY that prompt, then stop and report.

## What this is
A take-home for a banking company's iOS role. Reviewers read: code structure, failure handling, what the user sees when something goes wrong, tests, commit history. "Working code is not enough." Planned effort 2-3 hours (hard stop at 4). Quality and correctness over feature count. The UI is deliberately plain; no design/animation/accessibility/localization/Keychain/pinning/widgets/push/login/multi-account work. Do NOT spend effort on those.

The three questions the design must answer clearly:
1. What is the single source of truth?
2. What exists between the tap and the bank's confirmation?
3. What does the screen say when we do not know whether the money moved?

## Project facts
- Project name: `EvaLedger` (Xcode project `EvaLedger.xcodeproj`, scheme `EvaLedger`, test target `EvaLedgerTests`).
- SwiftUI app, Swift Testing (`import Testing`, `@Test`, `#expect`) for ALL tests. No XCTest, no UI tests.
- The Xcode project already exists and uses file-system synchronized groups. Create files on disk in the right folders; NEVER edit `project.pbxproj` by hand.
- This is an exercise with a made-up bank. Do not use any real bank's name, logo or branding anywhere (not in code, comments, bundle id, UI strings).

## Hard technical constraints
- Swift 6 language mode, strict concurrency ON, iOS 17+, SwiftUI + Observation.
- Zero third-party dependencies. No SwiftData / Core Data / CloudKit / Firebase / Realm / any framework that solves synchronization for us. Persistence = our own Codable JSON file, atomic writes, schema-versioned.
- The app talks to the bank ONLY through real HTTP requests via its own URLSession code. The fake bank answers as a URLProtocol registered on that session. The app NEVER calls the fake directly (except the DEBUG remote-control panel and the composition root).
- The fake bank lives in ONE file: `FakeBank.swift` (in the app target so the debug UI can use it; tests use `@testable import`). It keeps its own in-memory state, completely separate from app storage.
- Tests must run with Cmd+U with nothing else running. No real network, no real servers, no real sleeping (inject a Sleeper), no real wall-clock dependence.
- Money is Int cents everywhere. Never Double/Float for money. Never use own arithmetic to display a balance.
- No force unwraps, no `try!`, no `fatalError` in production paths, no print debugging left behind.

## The bank contract (made-up bank; follow it exactly)
Users: eva, alex, mila, noor, each starts at 100000 cents (1,000.00). The app is always eva (no login).

GET /v1/transactions?cursor=<cursor>   (omit cursor on first call)
200 {
  "transactions": [ { "id": "txn_d9a2549f", "from_username": "eva", "to_username": "alex",
     "amount_cents": 2500, "description": "lunch", "status": "completed",
     "rejection_reason": null, "idempotency_key": "k1" } ],
  "cursor": 4,
  "balance_cents": 97500 }
- Only transactions involving eva. The feed is a LIST OF CHANGES, not a list of transactions: a transaction is delivered again every time its status changes (and may be re-sent at any time). MERGE BY id: replace if present, else add. Never append.
- balance_cents = eva's balance at the bank at the moment it answered. It is the ONLY balance the bank provides. If it disagrees with our arithmetic, the bank is right.

POST /v1/payments
Body: { "to_username", "amount_cents", "description", "idempotency_key" }  (key is optional for the bank; WE ALWAYS SEND ONE)
- 201 { "transaction": {...}, "replayed": false }: the bank ACCEPTED it. New payment is "pending" and eva is debited at once. Later it settles to "completed" (recipient credited). A completed payment can later become "rejected" (eva refunded, rejection_reason says why). 201 does NOT mean success.
- Same key seen before from eva -> 200 { "transaction": <the original>, "replayed": true }, no second payment.
- Final errors (nothing happened, retrying won't help): 404 unknown_user, 422 invalid_amount, 422 self_payment, 422 insufficient_funds. Body: {"error":{"code":"...","message":"..."}}
- 503, or 429 with Retry-After (seconds): nothing happened; retry the SAME request after the delay.

## The six misbehaviors (each is a switch on the fake)
1. Lost answer: the bank creates the payment, then the connection drops; the app sees URLError.networkConnectionLost. The payment HAPPENED.
2. Unreachable: request never reaches the bank; app sees URLError.notConnectedToInternet. Nothing happened.
3. Busy: 503, or 429 + Retry-After. Nothing happened. Retry same request after the delay.
4. Repeated entries: next feed page contains every transaction twice, or re-sends already-received transactions (re-sent copy shows CURRENT state).
5. Balance ahead of the feed: when someone pays eva, balance_cents includes the money at once, but the transaction stays out of the feed until the fake releases it.
6. Late rejection: bank flips a completed payment to rejected and refunds eva.
The fake also needs: someone else pays eva; settle pending payments on command (never on a timer).

## The eight must-haves
1 Show balance + transactions.
2 Never let an unconfirmed payment look confirmed (from tap until bank confirms, user sees it is not confirmed).
3 Survive being killed at any instant: on relaunch the payment is never silently lost and never sent twice; either it goes through or the app shows it was NOT sent.
4 Never pay twice: one tap = at most one transaction, even when the answer never arrives or the feed repeats entries.
5 Bank wins on balance.
6 Late rejection shown as rejected with the bank's corrected balance.
7 Honest when unreachable: show last-known data marked possibly out of date; if the bank never received a payment show it as not sent and let the USER decide to retry; NEVER queue a payment to go out later on its own.
8 One test per scenario asserting rows, their states, the balance, and how many transactions the bank itself holds.

## Architecture decisions (non-negotiable; ask before deviating)
1. SINGLE SOURCE OF TRUTH: one persisted `LedgerState` (Codable, `schemaVersion`):
   - transactions keyed by id (with a locally assigned monotonically increasing `firstSeenOrder` for stable ordering, since the bank gives no timestamps)
   - `cursor: Int?`, `bankBalanceCents: Int?`, `balanceAsOf: Date?`
   - `attempts: [PaymentAttempt]`
   The UI renders ONLY a pure projection `LedgerState -> [TransactionRow] + BalanceDisplay`. No parallel arrays, no view-owned copies.
2. PaymentAttempt = what exists between the tap and the bank's confirmation. Fields: id (UUID), idempotencyKey (String, generated ONCE at tap, persisted), toUsername, amountCents, description, createdAt, state in { sending, unconfirmed, notSent(reason), failed(code,message) }.
   An attempt is DELETED (atomically with the write that stores the bank's transaction) as soon as a transaction with the same idempotency_key exists in the ledger, whatever state the attempt was in. Matching by key is how we avoid double rows.
3. WRITE-AHEAD: on tap, persist the attempt (state .sending) atomically BEFORE issuing the request. Killing the process at any instant afterwards must leave a recoverable disk state.
4. A persisted `.sending` attempt found at launch (not in this process's in-memory in-flight set) is orphaned and must be treated as `.unconfirmed` (it may have reached the bank).
5. Transport classification for POST /v1/payments:
   - URLError.notConnectedToInternet -> definitely not sent -> `.notSent`.
   - 429/503 -> busy: bounded retry of the SAME request (same key), honoring Retry-After (seconds, capped), exponential backoff when no header, max 5 total attempts, all sleeping via injected Sleeper. If budget exhausted -> `.notSent("bank busy")`.
   - 404/422 known codes -> `.failed(code,message)` (final; no retry).
   - networkConnectionLost, timedOut, cancelled, any other URLError, 5xx other than 503, undecodable 2xx -> AMBIGUOUS -> `.unconfirmed`.
   - 200/201 -> upsert returned transaction into ledger ONLY IF its id is absent (feed copies are always at least as fresh), delete the attempt.
6. RECONCILIATION is read-only: a successful sync that merges the feed resolves attempts by key. After a fully successful sync, any attempt in `.unconfirmed` (or orphaned) that has no key match becomes `.notSent`. NEVER mark an attempt notSent while its request is in flight in this process. Matching by key always wins later too: if a notSent attempt's transaction shows up in the feed afterwards, the attempt disappears and the real transaction row shows.
7. User retry of a `.notSent` attempt reuses the SAME attempt and SAME idempotency key (so even if the "not sent" verdict was wrong, the bank dedupes). `.failed` attempts can only be dismissed. `.notSent` can be retried or dismissed.
8. The app NEVER issues POST /v1/payments except as a direct consequence of a user tap/retry. Never on launch, never from sync, never from a timer.
9. Feed merge: upsert by id; within one page last occurrence wins; cursor = max(old, new) and is persisted in the SAME atomic write as the merged transactions and balance. Balance = response.balance_cents verbatim.
10. Staleness: `isStale` is true at launch (data came from disk), false after a successful sync, true again after any failed/ambiguous network interaction. UI shows last known data with a visible "possibly out of date" marker + balanceAsOf.
11. Concurrency: one actor owns the ledger and persistence. Sync is single-flight (concurrent callers await the same in-flight task). Every mutation = one atomic persist. The POST response and a feed page can interleave; the rules above make that safe.
12. Injectables for determinism: Sleeper, IDGenerator (idempotency keys/attempt ids), Clock (Date), storage URL. Production uses real ones.
13. The sync trigger (launch refresh, pull-to-refresh, optional polling timer) lives in the app layer. The core engine has NO timers, so tests are exact. The engine does NOT auto-sync after a send; the thin view model calls sync afterwards.

## Working agreement
- Write the failing test first, see it fail for the RIGHT reason, then implement.
- After EVERY change run the full test suite via xcodebuild. Discover an available simulator with `xcrun simctl list devices available`, then e.g. `xcodebuild test -project EvaLedger.xcodeproj -scheme EvaLedger -destination 'platform=iOS Simulator,name=<available iPhone>' -quiet`. Never claim something works without showing green test output.
- When a spec point is ambiguous, STOP and ask, listing the options and your recommendation. Do not silently pick.
- Prefer small types with one job. No god objects. No premature abstraction, but protocols at the real seams (BankClient, Persistence, Sleeper).
- At the end of each task: summarize what changed, what you assumed, and anything you are unsure about. Be honest about doubts. Do not praise your own work.

## Commit conventions (the history is reviewed)
- Small, focused commits. Imperative mood, specific subject line under ~60 chars. Good: `Persist payment attempt before network call`. Bad: `fix stuff`, `update`, `wip`.
- Never squash. Never amend or rewrite history. Never force-push.
- Test-first means two commits where it makes sense: first `Add failing test: <behavior>` (the test is red for the right reason), then the implementation commit that turns it green. If the suite must stay green on every commit, say so and ask which style the user prefers.
- A bug fix found in review or by the user is its own commit: `Fix: <what was wrong>`. Body (2-4 lines) says why it was wrong.
- Commit only when the full suite is green, except for an explicit red "failing test" commit.
- Do not commit build products, DerivedData, xcuserdata, .DS_Store.

## Files in this repo that are part of the deliverable
- `AGENTS.md` (this file), `PROMPTS.md` (ordered prompts), `NOTES.md` (reviewer-facing notes, written in Prompt 16), `README.md`.
- `WORKLOG.md` is the human's private scratchpad. Do NOT edit it. Do NOT copy its contents into NOTES.md sections 2 and 3; the human writes those.
