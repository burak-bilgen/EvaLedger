//
//  BusyRetryPolicy.swift
//  EvaLedger
//

import Foundation

nonisolated public protocol Sleeper: Sendable {
    func sleep(for duration: TimeInterval) async throws
}

nonisolated public struct RealSleeper: Sleeper {
    public init() {}

    public func sleep(for duration: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, duration) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

nonisolated public struct BusyRetryPolicy: Sendable {
    public static let maxAttempts = 5
    public static let maxRetryAfterCap: TimeInterval = 30.0

    /// Returns deterministic delay for the given attempt index (0-based) and optional Retry-After header.
    /// Backoff: 0.5s, 1.0s, 2.0s, 4.0s (capped at 30s).
    public static func delay(forAttemptIndex attemptIndex: Int, retryAfterHeader: TimeInterval?) -> TimeInterval {
        if let retryAfter = retryAfterHeader {
            return min(max(0, retryAfter), maxRetryAfterCap)
        }
        // Exponential backoff: 0.5 * 2^attemptIndex
        let computed = 0.5 * pow(2.0, Double(attemptIndex))
        return min(computed, maxRetryAfterCap)
    }

    /// Executes the payment action with bounded retries on `.busy` responses.
    /// Re-sends the identical request with the same idempotency key.
    /// Throws CancellationError if Task is cancelled.
    public static func execute(
        sleeper: any Sleeper,
        action: () async -> PaymentOutcome
    ) async -> PaymentOutcome {
        for attemptIndex in 0..<maxAttempts {
            if Task.isCancelled {
                return .ambiguous(reason: "Task was cancelled")
            }

            let outcome = await action()
            switch outcome {
            case .busy(let retryAfter):
                if attemptIndex + 1 < maxAttempts {
                    let waitTime = delay(forAttemptIndex: attemptIndex, retryAfterHeader: retryAfter)
                    do {
                        try await sleeper.sleep(for: waitTime)
                    } catch {
                        return .ambiguous(reason: "Sleep was cancelled: \(error.localizedDescription)")
                    }
                } else {
                    // Budget exhausted
                    return .definitelyNotSent
                }
            default:
                return outcome
            }
        }

        return .definitelyNotSent
    }
}
