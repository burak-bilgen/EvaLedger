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
