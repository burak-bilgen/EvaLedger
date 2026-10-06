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

    public var now: Date {
        Date()
    }
}
