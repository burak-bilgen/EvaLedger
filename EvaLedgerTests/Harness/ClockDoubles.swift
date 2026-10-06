//
//  ClockDoubles.swift
//  EvaLedgerTests
//

import Foundation
@testable import EvaLedger

public final class FixedClock: EngineClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(initialDate: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = initialDate
    }

    public var now: Date {
        lock.withLock { current }
    }

    public func advance(by seconds: TimeInterval) {
        lock.withLock {
            current = current.addingTimeInterval(seconds)
        }
    }
}
