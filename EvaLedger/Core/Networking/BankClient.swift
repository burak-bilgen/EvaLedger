//
//  BankClient.swift
//  EvaLedger
//

import Foundation

nonisolated public enum PaymentOutcome: Equatable, Sendable {
    case accepted(Transaction, replayed: Bool)
    case rejectedFinal(code: String, message: String)
    case busy(retryAfter: TimeInterval?)
    case definitelyNotSent(reason: String)
    case ambiguous(reason: String)

    public static var definitelyNotSent: PaymentOutcome {
        .definitelyNotSent(reason: "Payment was not received by bank")
    }
}


nonisolated public enum BankClientError: Error, Equatable, Sendable {
    case transport(String)
    case decoding(String)
    case busyExhausted
}

nonisolated public protocol BankClient: Sendable {
    func fetchFeed(cursor: Int?) async throws -> FeedResponse
    func createPayment(_ request: PaymentRequest) async -> PaymentOutcome
}

nonisolated public final class URLSessionBankClient: BankClient {
    public let session: URLSession
    public let baseURL: URL
    public let requestTimeout: TimeInterval

    public init(session: URLSession, baseURL: URL, requestTimeout: TimeInterval = 10.0) {
        self.session = session
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
    }

    public func fetchFeed(cursor: Int?) async throws -> FeedResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/transactions"), resolvingAgainstBaseURL: false)
        if let cursor = cursor {
            components?.queryItems = [URLQueryItem(name: "cursor", value: String(cursor))]
        }

        guard let url = components?.url else {
            throw BankClientError.transport("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BankClientError.transport("Invalid response type")
            }

            if httpResponse.statusCode == 200 {
                do {
                    return try JSONDecoder().decode(FeedResponse.self, from: data)
                } catch {
                    throw BankClientError.decoding(error.localizedDescription)
                }
            } else if httpResponse.statusCode == 503 || httpResponse.statusCode == 429 {
                throw BankClientError.busyExhausted
            } else {
                throw BankClientError.transport("HTTP \(httpResponse.statusCode)")
            }
        } catch let clientError as BankClientError {
            throw clientError
        } catch {
            throw BankClientError.transport(error.localizedDescription)
        }
    }

    public func createPayment(_ paymentRequest: PaymentRequest) async -> PaymentOutcome {
        let url = baseURL.appendingPathComponent("v1/payments")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            request.httpBody = try JSONEncoder().encode(paymentRequest)
        } catch {
            return .ambiguous(reason: "Failed to encode payment request: \(error.localizedDescription)")
        }

        do {
            let (data, response) = try await session.data(for: request)
            return Self.mapOutcome(data: data, response: response, error: nil)
        } catch {
            return Self.mapOutcome(data: nil, response: nil, error: error)
        }
    }

    /// Pure mapping function: status code + headers + body + error -> PaymentOutcome
    public static func mapOutcome(data: Data?, response: URLResponse?, error: (any Error)?) -> PaymentOutcome {
        if let error = error {
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet:
                    return .definitelyNotSent
                case .networkConnectionLost, .timedOut, .cancelled:
                    return .ambiguous(reason: "URLError: \(urlError.localizedDescription)")
                default:
                    return .ambiguous(reason: "URLError: \(urlError.localizedDescription)")
                }
            }
            return .ambiguous(reason: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return .ambiguous(reason: "Missing or invalid HTTPURLResponse")
        }

        let statusCode = httpResponse.statusCode

        // 200 OK (replayed) or 201 Created (accepted)
        if statusCode == 200 || statusCode == 201 {
            guard let data = data else {
                return .ambiguous(reason: "Missing response data on \(statusCode)")
            }
            do {
                let paymentResponse = try JSONDecoder().decode(PaymentResponse.self, from: data)
                return .accepted(paymentResponse.transaction, replayed: paymentResponse.replayed)
            } catch {
                return .ambiguous(reason: "Undecodable \(statusCode) response: \(error.localizedDescription)")
            }
        }

        // 429 Too Many Requests
        if statusCode == 429 {
            let retryAfterSeconds: TimeInterval?
            if let headerValue = httpResponse.value(forHTTPHeaderField: "Retry-After"),
               let seconds = Double(headerValue) {
                retryAfterSeconds = seconds
            } else {
                retryAfterSeconds = nil
            }
            return .busy(retryAfter: retryAfterSeconds)
        }

        // 503 Service Unavailable
        if statusCode == 503 {
            let retryAfterSeconds: TimeInterval?
            if let headerValue = httpResponse.value(forHTTPHeaderField: "Retry-After"),
               let seconds = Double(headerValue) {
                retryAfterSeconds = seconds
            } else {
                retryAfterSeconds = nil
            }
            return .busy(retryAfter: retryAfterSeconds)
        }

        // 404 Not Found & 422 Unprocessable Entity (Final rejection errors)
        if statusCode == 404 || statusCode == 422 {
            if let data = data,
               let errorBody = try? JSONDecoder().decode(BankErrorBody.self, from: data) {
                return .rejectedFinal(code: errorBody.error.code, message: errorBody.error.message)
            }
            return .rejectedFinal(code: "http_\(statusCode)", message: "Request failed with HTTP \(statusCode)")
        }

        // 5xx other than 503 -> AMBIGUOUS
        if statusCode >= 500 && statusCode < 600 {
            return .ambiguous(reason: "Server error HTTP \(statusCode)")
        }

        // Any other code (e.g. 400)
        return .ambiguous(reason: "Unexpected status HTTP \(statusCode)")
    }
}
