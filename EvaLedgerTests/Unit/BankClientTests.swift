//
//  BankClientTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

struct BankClientTests {

    private func makeHTTPResponse(statusCode: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        return HTTPURLResponse(
            url: URL(string: "https://bank.test/v1/payments")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    // MARK: - Table-driven outcome mapping tests

    @Test func mapOutcome201Accepted() throws {
        let json = """
        {
          "transaction": {
            "id": "txn_123", "from_username": "eva", "to_username": "alex",
            "amount_cents": 2500, "description": "lunch", "status": "pending",
            "rejection_reason": null, "idempotency_key": "k1"
          },
          "replayed": false
        }
        """.data(using: .utf8)!

        let outcome = URLSessionBankClient.mapOutcome(data: json, response: makeHTTPResponse(statusCode: 201), error: nil)
        switch outcome {
        case .accepted(let txn, let replayed):
            #expect(txn.id == "txn_123")
            #expect(replayed == false)
        default:
            Issue.record("Expected .accepted")
        }
    }

    @Test func mapOutcome200Replayed() throws {
        let json = """
        {
          "transaction": {
            "id": "txn_123", "from_username": "eva", "to_username": "alex",
            "amount_cents": 2500, "description": "lunch", "status": "pending",
            "rejection_reason": null, "idempotency_key": "k1"
          },
          "replayed": true
        }
        """.data(using: .utf8)!

        let outcome = URLSessionBankClient.mapOutcome(data: json, response: makeHTTPResponse(statusCode: 200), error: nil)
        switch outcome {
        case .accepted(let txn, let replayed):
            #expect(txn.id == "txn_123")
            #expect(replayed == true)
        default:
            Issue.record("Expected .accepted(replayed: true)")
        }
    }

    @Test func mapOutcome201WithGarbageJSONIsAmbiguous() {
        let garbage = "not valid json".data(using: .utf8)!
        let outcome = URLSessionBankClient.mapOutcome(data: garbage, response: makeHTTPResponse(statusCode: 201), error: nil)
        switch outcome {
        case .ambiguous:
            #expect(true)
        default:
            Issue.record("Expected .ambiguous on undecodable 201")
        }
    }

    @Test func mapOutcome404UnknownUser() {
        let json = """
        {"error":{"code":"unknown_user","message":"User not found"}}
        """.data(using: .utf8)!

        let outcome = URLSessionBankClient.mapOutcome(data: json, response: makeHTTPResponse(statusCode: 404), error: nil)
        #expect(outcome == .rejectedFinal(code: "unknown_user", message: "User not found"))
    }

    @Test func mapOutcome422Codes() {
        let codes = ["invalid_amount", "self_payment", "insufficient_funds"]
        for code in codes {
            let json = """
            {"error":{"code":"\(code)","message":"Message for \(code)"}}
            """.data(using: .utf8)!

            let outcome = URLSessionBankClient.mapOutcome(data: json, response: makeHTTPResponse(statusCode: 422), error: nil)
            #expect(outcome == .rejectedFinal(code: code, message: "Message for \(code)"))
        }
    }

    @Test func mapOutcome429WithAndWithoutRetryAfter() {
        // With Retry-After: 3
        let outcomeWith = URLSessionBankClient.mapOutcome(data: Data(), response: makeHTTPResponse(statusCode: 429, headers: ["Retry-After": "3"]), error: nil)
        #expect(outcomeWith == .busy(retryAfter: 3.0))

        // Without Retry-After
        let outcomeWithout = URLSessionBankClient.mapOutcome(data: Data(), response: makeHTTPResponse(statusCode: 429), error: nil)
        #expect(outcomeWithout == .busy(retryAfter: nil))
    }

    @Test func mapOutcome503ServiceUnavailable() {
        let outcome = URLSessionBankClient.mapOutcome(data: Data(), response: makeHTTPResponse(statusCode: 503), error: nil)
        #expect(outcome == .busy(retryAfter: nil))
    }

    @Test func mapOutcome500InternalServerErrorIsAmbiguous() {
        let outcome = URLSessionBankClient.mapOutcome(data: Data(), response: makeHTTPResponse(statusCode: 500), error: nil)
        switch outcome {
        case .ambiguous:
            #expect(true)
        default:
            Issue.record("Expected .ambiguous for 500")
        }
    }

    @Test func mapOutcome400UnknownErrorBodyIsAmbiguous() {
        let outcome = URLSessionBankClient.mapOutcome(data: Data(), response: makeHTTPResponse(statusCode: 400), error: nil)
        switch outcome {
        case .ambiguous:
            #expect(true)
        default:
            Issue.record("Expected .ambiguous for unknown 400")
        }
    }

    @Test func mapOutcomeTransportErrors() {
        // notConnectedToInternet -> definitelyNotSent
        let outcomeNotConnected = URLSessionBankClient.mapOutcome(data: nil, response: nil, error: URLError(.notConnectedToInternet))
        #expect(outcomeNotConnected == .definitelyNotSent)

        // networkConnectionLost -> ambiguous
        let outcomeLost = URLSessionBankClient.mapOutcome(data: nil, response: nil, error: URLError(.networkConnectionLost))
        switch outcomeLost {
        case .ambiguous: #expect(true)
        default: Issue.record("Expected ambiguous for networkConnectionLost")
        }

        // timedOut -> ambiguous
        let outcomeTimeout = URLSessionBankClient.mapOutcome(data: nil, response: nil, error: URLError(.timedOut))
        switch outcomeTimeout {
        case .ambiguous: #expect(true)
        default: Issue.record("Expected ambiguous for timedOut")
        }

        // cancelled -> ambiguous
        let outcomeCancelled = URLSessionBankClient.mapOutcome(data: nil, response: nil, error: URLError(.cancelled))
        switch outcomeCancelled {
        case .ambiguous: #expect(true)
        default: Issue.record("Expected ambiguous for cancelled")
        }
    }

    // MARK: - Retry loop tests with FakeBank

    @Test func retryLoopWithBusyResponsesSuccess() async throws {
        let bank = FakeBank(uniqueHost: UUID().uuidString + ".bank.test")
        let session = bank.makeSession()
        let client = URLSessionBankClient(session: session, baseURL: bank.baseURL)
        let sleeper = RecordingSleeper()

        // Arm FakeBank with 429 (Retry-After: 1) then 503
        bank.armBusy([
            .tooManyRequests(retryAfterSeconds: 1),
            .serviceUnavailable
        ])

        let request = PaymentRequest(toUsername: "alex", amountCents: 2500, description: "lunch", idempotencyKey: "k_busy_loop")

        let finalOutcome = await BusyRetryPolicy.execute(sleeper: sleeper) {
            await client.createPayment(request)
        }

        switch finalOutcome {
        case .accepted(let txn, _):
            #expect(txn.amountCents == 2500)
        default:
            Issue.record("Expected final outcome .accepted")
        }

        // Verify Sleeper recorded durations:
        // First sleep was 1.0s (from Retry-After header)
        // Second sleep was 1.0s (from exponential backoff attemptIndex 1 = 0.5 * 2^1 = 1.0s)
        #expect(sleeper.requestedDurations.count == 2)
        #expect(sleeper.requestedDurations[0] == 1.0)
        #expect(sleeper.requestedDurations[1] == 1.0)

        // Requests that hit the bank used the identical idempotency key
        let postEntries = bank.requestLog.filter { $0.method == "POST" }
        #expect(postEntries.count == 3)
        for entry in postEntries {
            #expect(entry.idempotencyKey == "k_busy_loop")
        }
    }

    @Test func retryLoopExhaustionReturnsDefinitelyNotSent() async {
        let sleeper = RecordingSleeper()

        // Execute action that always returns busy
        var callCount = 0
        let outcome = await BusyRetryPolicy.execute(sleeper: sleeper) {
            callCount += 1
            return .busy(retryAfter: nil)
        }

        #expect(outcome == .definitelyNotSent(reason: "bank busy"))
        #expect(callCount == 5) // maxAttempts == 5
        #expect(sleeper.requestedDurations.count == 4) // Slept 4 times before 5th attempt
        #expect(sleeper.requestedDurations[0] == 0.5)
        #expect(sleeper.requestedDurations[1] == 1.0)
        #expect(sleeper.requestedDurations[2] == 2.0)
        #expect(sleeper.requestedDurations[3] == 4.0)
    }

    @Test func fetchFeedRetriesOnBusyResponsesAndSucceeds() async throws {
        let bank = FakeBank(uniqueHost: UUID().uuidString + ".bank.test")
        let session = bank.makeSession()
        let sleeper = RecordingSleeper()
        let client = URLSessionBankClient(session: session, baseURL: bank.baseURL, sleeper: sleeper)

        bank.armBusy([
            .tooManyRequests(retryAfterSeconds: 2),
            .serviceUnavailable
        ])

        let feed = try await client.fetchFeed(cursor: nil)
        #expect(feed.balanceCents == 100000)
        #expect(sleeper.requestedDurations.count == 2)
        #expect(sleeper.requestedDurations[0] == 2.0)
        #expect(sleeper.requestedDurations[1] == 1.0)
    }
}
