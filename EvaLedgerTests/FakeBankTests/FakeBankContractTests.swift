//
//  FakeBankContractTests.swift
//  EvaLedgerTests
//

import Foundation
import Testing
@testable import EvaLedger

struct FakeBankContractTests {

    private func makeBank() -> FakeBank {
        return FakeBank(uniqueHost: UUID().uuidString + ".bank.test")
    }

    private func getFeed(bank: FakeBank, session: URLSession, cursor: Int? = nil) async throws -> (FeedResponse, HTTPURLResponse) {
        var urlComponents = URLComponents(url: bank.baseURL.appendingPathComponent("v1/transactions"), resolvingAgainstBaseURL: false)!
        if let cursor = cursor {
            urlComponents.queryItems = [URLQueryItem(name: "cursor", value: String(cursor))]
        }

        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        let feed = try JSONDecoder().decode(FeedResponse.self, from: data)
        return (feed, httpResponse)
    }

    private func postPayment(bank: FakeBank, session: URLSession, request: PaymentRequest) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = URLRequest(url: bank.baseURL.appendingPathComponent("v1/payments"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        let httpResponse = response as! HTTPURLResponse
        return (data, httpResponse)
    }

    @Test func firstCallFeedReturnsEvaBalanceAndEmptyTransactions() async throws {
        let bank = makeBank()
        let session = bank.makeSession()

        let (feed, response) = try await getFeed(bank: bank, session: session)
        #expect(response.statusCode == 200)
        #expect(feed.balanceCents == 100000)
        #expect(feed.transactions.isEmpty)
    }

    @Test func paymentCreation201AndDebitAtOnce() async throws {
        let bank = makeBank()
        let session = bank.makeSession()

        let paymentRequest = PaymentRequest(toUsername: "alex", amountCents: 2500, description: "lunch", idempotencyKey: "k_201")
        let (data, response) = try await postPayment(bank: bank, session: session, request: paymentRequest)

        #expect(response.statusCode == 201)
        let paymentResponse = try JSONDecoder().decode(PaymentResponse.self, from: data)
        #expect(paymentResponse.replayed == false)
        #expect(paymentResponse.transaction.amountCents == 2500)
        #expect(paymentResponse.transaction.status == .pending)
        #expect(paymentResponse.transaction.fromUsername == "eva")
        #expect(paymentResponse.transaction.toUsername == "alex")

        // Eva is debited at once
        #expect(bank.balance(of: "eva") == 97500)
        // Recipient is NOT credited until settle
        #expect(bank.balance(of: "alex") == 100000)

        // Inspection counts
        #expect(bank.paymentRequestCount == 1)
        #expect(bank.transactionCount(from: "eva") == 1)
    }

    @Test func settlePendingCreditsRecipientAndDeliversCompletedInFeed() async throws {
        let bank = makeBank()
        let session = bank.makeSession()

        let paymentRequest = PaymentRequest(toUsername: "alex", amountCents: 2500, description: "lunch", idempotencyKey: "k_settle")
        _ = try await postPayment(bank: bank, session: session, request: paymentRequest)

        // Settle pending payments
        bank.settlePending()

        #expect(bank.balance(of: "eva") == 97500)
        #expect(bank.balance(of: "alex") == 102500)

        let (feed, _) = try await getFeed(bank: bank, session: session)
        #expect(feed.transactions.count == 1)
        #expect(feed.transactions.first?.status == .completed)
        #expect(feed.balanceCents == 97500)
    }

    @Test func replay200ReturnsOriginalTransactionWithoutSecondDebit() async throws {
        let bank = makeBank()
        let session = bank.makeSession()

        let paymentRequest = PaymentRequest(toUsername: "alex", amountCents: 2500, description: "lunch", idempotencyKey: "k_replay")

        // First send -> 201
        let (data1, resp1) = try await postPayment(bank: bank, session: session, request: paymentRequest)
        #expect(resp1.statusCode == 201)
        let firstTx = try JSONDecoder().decode(PaymentResponse.self, from: data1).transaction

        // Second send with same key -> 200 replayed: true
        let (data2, resp2) = try await postPayment(bank: bank, session: session, request: paymentRequest)
        #expect(resp2.statusCode == 200)
        let secondResponse = try JSONDecoder().decode(PaymentResponse.self, from: data2)
        #expect(secondResponse.replayed == true)
        #expect(secondResponse.transaction.id == firstTx.id)

        // Eva debited only ONCE
        #expect(bank.balance(of: "eva") == 97500)
        #expect(bank.transactionCount(from: "eva") == 1)
    }

    @Test func finalErrorsValidationOrder() async throws {
        let bank = makeBank()
        let session = bank.makeSession()

        // 404 unknown_user
        let reqUnknown = PaymentRequest(toUsername: "nobody", amountCents: 1000, description: "test", idempotencyKey: "k_err1")
        let (data404, resp404) = try await postPayment(bank: bank, session: session, request: reqUnknown)
        #expect(resp404.statusCode == 404)
        let err404 = try JSONDecoder().decode(BankErrorBody.self, from: data404)
        #expect(err404.error.code == "unknown_user")

        // 422 invalid_amount (<= 0)
        let reqZero = PaymentRequest(toUsername: "alex", amountCents: 0, description: "test", idempotencyKey: "k_err2")
        let (dataZero, respZero) = try await postPayment(bank: bank, session: session, request: reqZero)
        #expect(respZero.statusCode == 422)
        let errZero = try JSONDecoder().decode(BankErrorBody.self, from: dataZero)
        #expect(errZero.error.code == "invalid_amount")

        // 422 self_payment
        let reqSelf = PaymentRequest(toUsername: "eva", amountCents: 1000, description: "test", idempotencyKey: "k_err3")
        let (dataSelf, respSelf) = try await postPayment(bank: bank, session: session, request: reqSelf)
        #expect(respSelf.statusCode == 422)
        let errSelf = try JSONDecoder().decode(BankErrorBody.self, from: dataSelf)
        #expect(errSelf.error.code == "self_payment")

        // 422 insufficient_funds
        let reqBroke = PaymentRequest(toUsername: "alex", amountCents: 500000, description: "test", idempotencyKey: "k_err4")
        let (dataBroke, respBroke) = try await postPayment(bank: bank, session: session, request: reqBroke)
        #expect(respBroke.statusCode == 422)
        let errBroke = try JSONDecoder().decode(BankErrorBody.self, from: dataBroke)
        #expect(errBroke.error.code == "insufficient_funds")

        // None of these mutated balance
        #expect(bank.balance(of: "eva") == 100000)
        #expect(bank.transactionCount(from: "eva") == 0)
    }

    @Test func switch1LostAnswerCreatesPaymentAndThrowsNetworkConnectionLost() async throws {
        let bank = makeBank()
        let session = bank.makeSession()

        bank.armLostAnswer()
        let paymentRequest = PaymentRequest(toUsername: "alex", amountCents: 2500, description: "lunch", idempotencyKey: "k_lost")

        do {
            _ = try await postPayment(bank: bank, session: session, request: paymentRequest)
            Issue.record("Expected networkConnectionLost error")
        } catch let error as URLError {
            #expect(error.code == .networkConnectionLost)
        }

        // The payment HAPPENED at the bank!
        #expect(bank.balance(of: "eva") == 97500)
        #expect(bank.transactionCount(from: "eva") == 1)
        #expect(bank.paymentRequestCount == 1)
    }

    @Test func switch2UnreachableFailsWithNotConnectedToInternetLeavingStateUntouched() async throws {
        let bank = makeBank()
        let session = bank.makeSession()

        bank.setUnreachable(true)

        // Feed GET fails
        do {
            _ = try await getFeed(bank: bank, session: session)
            Issue.record("Expected notConnectedToInternet")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        }

        // Payment POST fails
        let paymentRequest = PaymentRequest(toUsername: "alex", amountCents: 2500, description: "lunch", idempotencyKey: "k_unreachable")
        do {
            _ = try await postPayment(bank: bank, session: session, request: paymentRequest)
            Issue.record("Expected notConnectedToInternet")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        }

        // Bank state completely untouched
        #expect(bank.balance(of: "eva") == 100000)
        #expect(bank.transactionCount(from: "eva") == 0)
    }

    @Test func switch3BusySequence429And503() async throws {
        let bank = makeBank()
        let session = bank.makeSession()

        bank.armBusy([
            .tooManyRequests(retryAfterSeconds: 3),
            .serviceUnavailable
        ])

        let paymentRequest = PaymentRequest(toUsername: "alex", amountCents: 2500, description: "lunch", idempotencyKey: "k_busy")

        // First call: 429
        let (_, resp1) = try await postPayment(bank: bank, session: session, request: paymentRequest)
        #expect(resp1.statusCode == 429)
        #expect(resp1.value(forHTTPHeaderField: "Retry-After") == "3")

        // Second call: 503
        let (_, resp2) = try await postPayment(bank: bank, session: session, request: paymentRequest)
        #expect(resp2.statusCode == 503)

        // Third call: normal 201
        let (_, resp3) = try await postPayment(bank: bank, session: session, request: paymentRequest)
        #expect(resp3.statusCode == 201)

        #expect(bank.balance(of: "eva") == 97500)
    }

    @Test func switch4RepeatedEntriesModes() async throws {
        let bank = makeBank()
        let session = bank.makeSession()

        let req1 = PaymentRequest(toUsername: "alex", amountCents: 2500, description: "lunch", idempotencyKey: "k_rep1")
        _ = try await postPayment(bank: bank, session: session, request: req1)

        // Mode 1: Duplicate within page
        bank.armRepeatedEntries(.duplicateWithinPage)
        let (feedDup, _) = try await getFeed(bank: bank, session: session)
        #expect(feedDup.transactions.count == 2)
        #expect(feedDup.transactions[0].id == feedDup.transactions[1].id)

        // Mode 2: Resend previously delivered
        // Create second transaction
        let req2 = PaymentRequest(toUsername: "mila", amountCents: 1000, description: "coffee", idempotencyKey: "k_rep2")
        _ = try await postPayment(bank: bank, session: session, request: req2)

        bank.armRepeatedEntries(.resendPreviouslyDelivered)
        // Fetch using cursor from feedDup
        let (feedResend, _) = try await getFeed(bank: bank, session: session, cursor: feedDup.cursor)
        // Must contain newly created transaction AND the previously delivered transaction
        #expect(feedResend.transactions.count == 2)
        let ids = Set(feedResend.transactions.map { $0.id })
        #expect(ids.count == 2)
    }

    @Test func switch5HeldTransactionsAndReleaseWithAdvancedCursor() async throws {
        let bank = makeBank()
        let session = bank.makeSession()

        // 1. Initial feed sync
        let (feed0, _) = try await getFeed(bank: bank, session: session)
        let initialCursor = feed0.cursor

        // 2. Incoming payment held from feed
        bank.setHoldIncomingFromFeed(true)
        bank.pay(from: "noor", amountCents: 1708, description: "split")

        // Eva balance increased immediately!
        #expect(bank.balance(of: "eva") == 101708)

        // Feed returns NO transactions
        let (feedHeld, _) = try await getFeed(bank: bank, session: session, cursor: initialCursor)
        #expect(feedHeld.transactions.isEmpty)
        #expect(feedHeld.balanceCents == 101708)

        let advancedCursor = feedHeld.cursor ?? initialCursor

        // 3. Release held transactions
        bank.releaseHeldTransactions()

        // Feed with advanced cursor now delivers the held payment with new sequence
        let (feedReleased, _) = try await getFeed(bank: bank, session: session, cursor: advancedCursor)
        #expect(feedReleased.transactions.count == 1)
        #expect(feedReleased.transactions[0].amountCents == 1708)
        #expect(feedReleased.transactions[0].fromUsername == "noor")
    }

    @Test func switch6LateRejectRefundsEvaAndReversesCounterpartyCredit() async throws {
        let bank = makeBank()
        let session = bank.makeSession()

        let req = PaymentRequest(toUsername: "alex", amountCents: 2500, description: "lunch", idempotencyKey: "k_late")
        let (data, _) = try await postPayment(bank: bank, session: session, request: req)
        let tx = try JSONDecoder().decode(PaymentResponse.self, from: data).transaction

        bank.settlePending()
        #expect(bank.balance(of: "eva") == 97500)
        #expect(bank.balance(of: "alex") == 102500)

        // Late reject
        bank.lateReject(transactionID: tx.id, reason: "The receiving bank refused it")

        // Balances restored
        #expect(bank.balance(of: "eva") == 100000)
        #expect(bank.balance(of: "alex") == 100000)

        // Feed reflects rejected status and reason
        let (feed, _) = try await getFeed(bank: bank, session: session)
        let rejectedTx = feed.transactions.first { $0.id == tx.id }!
        #expect(rejectedTx.status == .rejected)
        #expect(rejectedTx.rejectionReason == "The receiving bank refused it")
        #expect(feed.balanceCents == 100000)
    }
}
