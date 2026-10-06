//
//  RecordingSleeper.swift
//  EvaLedgerTests
//

import Foundation
@testable import EvaLedger

nonisolated public final class RecordingSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var _requestedDurations: [TimeInterval] = []

    public init() {}

    public func sleep(for duration: TimeInterval) async throws {
        record(duration)
    }

    private func record(_ duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        _requestedDurations.append(duration)
    }

    public var requestedDurations: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedDurations
    }
}
