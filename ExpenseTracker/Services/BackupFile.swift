import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The backup file, version 1. Every record keeps its original UUID. Dates are stored as
/// exact numbers (timeIntervalSinceReferenceDate) so a transfer's two legs stay equal.
/// Unknown extra keys are ignored when reading, so later versions can add data.
struct BackupFile: Codable, Equatable {
    static let currentVersion = 1

    var formatVersion: Int
    var appVersion: String
    var backupID: UUID
    var exportedAt: Double
    var wallets: [BackupWallet]
    var categories: [BackupCategory]
    var transactions: [BackupTransaction]
}

struct BackupWallet: Codable, Equatable {
    var id: UUID
    var name: String
    var emoji: String
    var openingBalanceMinor: Int64
    var currencyCode: String
    var createdAt: Double
    var isArchived: Bool
}

struct BackupCategory: Codable, Equatable {
    var id: UUID
    var name: String
    var emoji: String
    var colorHex: String
    var createdAt: Double
    var updatedAt: Double
    var isArchived: Bool
}

struct BackupTransaction: Codable, Equatable {
    var id: UUID
    var amountMinor: Int64
    var kindRaw: String
    var timestamp: Double
    var note: String
    var walletID: UUID
    var categoryID: UUID?
    var transferID: UUID?
}

/// Lets the system Files interface save the backup.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
