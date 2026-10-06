//
//  TransactionEncodingTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

struct TransactionEncodingTests {

    @Test func decodeFeedResponseExactSample() throws {
        let json = """
        {
          "transactions": [ { "id": "txn_d9a2549f", "from_username": "eva", "to_username": "alex",
             "amount_cents": 2500, "description": "lunch", "status": "completed",
             "rejection_reason": null, "idempotency_key": "k1" } ],
          "cursor": 4,
          "balance_cents": 97500 }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(FeedResponse.self, from: json)
        #expect(response.cursor == 4)
        #expect(response.balanceCents == 97500)
        #expect(response.transactions.count == 1)

        let txn = response.transactions[0]
        #expect(txn.id == "txn_d9a2549f")
        #expect(txn.fromUsername == "eva")
        #expect(txn.toUsername == "alex")
        #expect(txn.amountCents == 2500)
        #expect(txn.description == "lunch")
        #expect(txn.status == .completed)
        #expect(txn.rejectionReason == nil)
        #expect(txn.idempotencyKey == "k1")
    }

    @Test func decodePaymentResponseExactSample() throws {
        let json = """
        {
          "transaction": {
            "id": "txn_01234567",
            "from_username": "eva",
            "to_username": "mila",
            "amount_cents": 1200,
            "description": "coffee",
            "status": "pending",
            "rejection_reason": null,
            "idempotency_key": "key_123"
          },
          "replayed": false
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(PaymentResponse.self, from: json)
        #expect(response.replayed == false)
        #expect(response.transaction.id == "txn_01234567")
        #expect(response.transaction.status == .pending)
    }

    @Test func decodeBankErrorBody() throws {
        let json = """
        {
          "error": {
            "code": "insufficient_funds",
            "message": "Eva does not have enough balance."
          }
        }
        """.data(using: .utf8)!

        let errorBody = try JSONDecoder().decode(BankErrorBody.self, from: json)
        #expect(errorBody.error.code == "insufficient_funds")
        #expect(errorBody.error.message == "Eva does not have enough balance.")
    }

    @Test func decodeUnknownStatusWithoutCrashing() throws {
        let json = """
        {
          "id": "txn_unknown",
          "from_username": "eva",
          "to_username": "alex",
          "amount_cents": 500,
          "description": "test",
          "status": "future_unknown_status",
          "rejection_reason": null,
          "idempotency_key": null
        }
        """.data(using: .utf8)!

        let txn = try JSONDecoder().decode(Transaction.self, from: json)
        #expect(txn.status == .unknown("future_unknown_status"))
    }

    @Test func paymentAttemptRoundTripAllStates() throws {
        let uuid = UUID()
        let now = Date()

        let states: [AttemptState] = [
            .sending,
            .unconfirmed,
            .notSent(reason: "No internet connection"),
            .failed(code: "insufficient_funds", message: "Not enough cents")
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for state in states {
            let attempt = PaymentAttempt(
                id: uuid,
                idempotencyKey: "k_test",
                toUsername: "alex",
                amountCents: 2500,
                description: "lunch",
                createdAt: now,
                state: state
            )

            let data = try encoder.encode(attempt)
            let decoded = try decoder.decode(PaymentAttempt.self, from: data)

            #expect(decoded.id == uuid)
            #expect(decoded.idempotencyKey == "k_test")
            #expect(decoded.toUsername == "alex")
            #expect(decoded.amountCents == 2500)
            #expect(decoded.description == "lunch")
            #expect(decoded.state == state)
        }
    }
}
