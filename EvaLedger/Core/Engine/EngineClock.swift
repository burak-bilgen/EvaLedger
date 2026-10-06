//
//  EngineClock.swift
//  EvaLedger
//

import Foundation

nonisolated public protocol EngineClock: Sendable {
    var now: Date { get }
}

nonisolated public struct SystemClock: EngineClock {
    public init() {}
    public var now: Date { Date() }
}

nonisolated public final class FixedClock: EngineClock, @unchecked Sendable {
    private let lock = NSLock()
    private var currentDate: Date

    public init(date: Date = Date(timeIntervalSince1970: 1700000000)) {
        self.currentDate = date
    }

    public var now: Date {
        lock.withLock { currentDate }
    }

    public func advance(by seconds: TimeInterval) {
        lock.withLock { currentDate = currentDate.addingTimeInterval(seconds) }
    }

    public func set(date: Date) {
        lock.withLock { currentDate = date }
    }
}
