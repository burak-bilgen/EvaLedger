//
//  PaymentAttempt.swift
//  EvaLedger
//

import Foundation

// Schema Evolution Note:
// AttemptState uses an explicit type-discriminator string ("type") rather than Swift's synthesized enum
// encoding. This guarantees that renaming Swift enum cases or adding associated values in future versions
// will not corrupt persisted state across app updates.
nonisolated public enum AttemptState: Codable, Equatable, Sendable {
    case sending
    case unconfirmed
    case notSent(reason: String)
    case failed(code: String, message: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case reason
        case code
        case message
    }

    private enum StateType: String, Codable {
        case sending
        case unconfirmed
        case notSent = "not_sent"
        case failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(StateType.self, forKey: .type)
        switch type {
        case .sending:
            self = .sending
        case .unconfirmed:
            self = .unconfirmed
        case .notSent:
            let reason = try container.decode(String.self, forKey: .reason)
            self = .notSent(reason: reason)
        case .failed:
            let code = try container.decode(String.self, forKey: .code)
            let message = try container.decode(String.self, forKey: .message)
            self = .failed(code: code, message: message)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sending:
            try container.encode(StateType.sending, forKey: .type)
        case .unconfirmed:
            try container.encode(StateType.unconfirmed, forKey: .type)
        case .notSent(let reason):
            try container.encode(StateType.notSent, forKey: .type)
            try container.encode(reason, forKey: .reason)
        case .failed(let code, let message):
            try container.encode(StateType.failed, forKey: .type)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        }
    }
}

nonisolated public struct PaymentAttempt: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let idempotencyKey: String
    public let toUsername: String
    public let amountCents: Int
    public let description: String
    public let createdAt: Date
    public var state: AttemptState

    public init(
        id: UUID,
        idempotencyKey: String,
        toUsername: String,
        amountCents: Int,
        description: String,
        createdAt: Date,
        state: AttemptState
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.toUsername = toUsername
        self.amountCents = amountCents
        self.description = description
        self.createdAt = createdAt
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case idempotencyKey = "idempotency_key"
        case toUsername = "to_username"
        case amountCents = "amount_cents"
        case description
        case createdAt = "created_at"
        case state
    }
}
