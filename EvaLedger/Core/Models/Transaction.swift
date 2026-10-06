//
//  Transaction.swift
//  EvaLedger
//

import Foundation

nonisolated public enum TransactionStatus: Codable, Equatable, Sendable {
    case pending
    case completed
    case rejected
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "pending":
            self = .pending
        case "completed":
            self = .completed
        case "rejected":
            self = .rejected
        default:
            self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .pending:
            try container.encode("pending")
        case .completed:
            try container.encode("completed")
        case .rejected:
            try container.encode("rejected")
        case .unknown(let raw):
            try container.encode(raw)
        }
    }
}

nonisolated public struct Transaction: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let fromUsername: String
    public let toUsername: String
    public let amountCents: Int
    public let description: String
    public let status: TransactionStatus
    public let rejectionReason: String?
    public let idempotencyKey: String?

    public init(
        id: String,
        fromUsername: String,
        toUsername: String,
        amountCents: Int,
        description: String,
        status: TransactionStatus,
        rejectionReason: String? = nil,
        idempotencyKey: String? = nil
    ) {
        self.id = id
        self.fromUsername = fromUsername
        self.toUsername = toUsername
        self.amountCents = amountCents
        self.description = description
        self.status = status
        self.rejectionReason = rejectionReason
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case fromUsername = "from_username"
        case toUsername = "to_username"
        case amountCents = "amount_cents"
        case description
        case status
        case rejectionReason = "rejection_reason"
        case idempotencyKey = "idempotency_key"
    }
}

nonisolated public struct FeedResponse: Codable, Equatable, Sendable {
    public let transactions: [Transaction]
    public let cursor: Int?
    public let balanceCents: Int

    public init(transactions: [Transaction], cursor: Int?, balanceCents: Int) {
        self.transactions = transactions
        self.cursor = cursor
        self.balanceCents = balanceCents
    }

    private enum CodingKeys: String, CodingKey {
        case transactions
        case cursor
        case balanceCents = "balance_cents"
    }
}

nonisolated public struct PaymentRequest: Codable, Equatable, Sendable {
    public let toUsername: String
    public let amountCents: Int
    public let description: String
    public let idempotencyKey: String

    public init(toUsername: String, amountCents: Int, description: String, idempotencyKey: String) {
        self.toUsername = toUsername
        self.amountCents = amountCents
        self.description = description
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case toUsername = "to_username"
        case amountCents = "amount_cents"
        case description
        case idempotencyKey = "idempotency_key"
    }
}

nonisolated public struct PaymentResponse: Codable, Equatable, Sendable {
    public let transaction: Transaction
    public let replayed: Bool

    public init(transaction: Transaction, replayed: Bool) {
        self.transaction = transaction
        self.replayed = replayed
    }

    private enum CodingKeys: String, CodingKey {
        case transaction
        case replayed
    }
}

nonisolated public struct BankErrorBody: Codable, Equatable, Sendable {
    nonisolated public struct Details: Codable, Equatable, Sendable {
        public let code: String
        public let message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }

        private enum CodingKeys: String, CodingKey {
            case code
            case message
        }
    }

    public let error: Details

    public init(error: Details) {
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case error
    }
}
