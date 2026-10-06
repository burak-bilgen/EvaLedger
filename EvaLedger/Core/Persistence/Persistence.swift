//
//  Persistence.swift
//  EvaLedger
//

import Foundation

nonisolated public enum PersistenceError: Error, Sendable {
    case fileCorrupt(url: URL, backupURL: URL, underlying: any Error)
    case unsupportedSchemaVersion(Int)
    case writeFailed(any Error)
}

nonisolated public protocol Persistence: Sendable {
    func load() throws -> LedgerState?
    func save(_ state: LedgerState) throws
}
