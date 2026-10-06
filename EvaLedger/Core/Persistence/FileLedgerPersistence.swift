//
//  FileLedgerPersistence.swift
//  EvaLedger
//

import Foundation

nonisolated public final class FileLedgerPersistence: Persistence {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> LedgerState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw PersistenceError.writeFailed(error)
        }

        // Parse schema version first to detect future incompatible schemas
        struct SchemaProbe: Decodable {
            let schema_version: Int
        }

        let decoder = JSONDecoder()

        do {
            let probe = try decoder.decode(SchemaProbe.self, from: data)
            if probe.schema_version > LedgerState.currentSchemaVersion {
                throw PersistenceError.unsupportedSchemaVersion(probe.schema_version)
            }
        } catch let err as PersistenceError {
            throw err
        } catch {
            // Bad format or corrupted file
            return try handleCorruptFile(data: data, underlying: error)
        }

        do {
            let state = try decoder.decode(LedgerState.self, from: data)
            return state
        } catch {
            return try handleCorruptFile(data: data, underlying: error)
        }
    }

    public func save(_ state: LedgerState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw PersistenceError.writeFailed(error)
        }

        let parentDir = fileURL.deletingLastPathComponent()
        do {
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw PersistenceError.writeFailed(error)
        }
    }

    // Preservation Choice Rationale:
    // We intentionally copy the corrupted file to a `.corrupt` backup instead of overwriting or deleting it.
    // In financial ledgers, a corrupt file could contain records of pending or unconfirmed payments that were
    // in flight. Overwriting with empty data would silently destroy money-relevant audit trails.
    // Creating a timestamped forensic backup preserves the raw data for investigation and data recovery.
    private func handleCorruptFile(data: Data, underlying: any Error) throws -> LedgerState? {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = fileURL.appendingPathExtension("corrupt.\(timestamp)")
        try? data.write(to: backupURL, options: .atomic)
        throw PersistenceError.fileCorrupt(url: fileURL, backupURL: backupURL, underlying: underlying)
    }
}
