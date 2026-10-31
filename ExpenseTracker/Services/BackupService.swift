import Foundation
import SwiftData

enum BackupError: Error, Equatable {
    case unreadable
    case tooLarge
    case newerVersion
    case unsupportedVersion
    case unknownKind
    case invalid(String)
    case unsavedChanges
    case saveFailed

    var message: String {
        switch self {
        case .unreadable:
            return "This file isn't a backup this app can read."
        case .tooLarge:
            return "This file is too large to be a backup."
        case .newerVersion:
            return "This backup was made by a newer version of the app. Update the app and try again."
        case .unsupportedVersion:
            return "This backup's format isn't supported."
        case .unknownKind:
            return "This backup contains data this version can't read. Update the app and try again."
        case .invalid(let detail):
            return "This backup can't be used. \(detail)"
        case .unsavedChanges:
            return "There are unsaved changes. Close any open screens and try again."
        case .saveFailed:
            return "The restore couldn't be completed."
        }
    }
}

struct BackupSummary: Equatable {
    let wallets: Int
    let categories: Int
    let transactions: Int
    let exportedAt: Date

    var text: String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        let when = exportedAt.formatted(date: .abbreviated, time: .omitted)
        return "\(count(wallets, "wallet", "wallets")), \(count(categories, "category", "categories")), "
            + "\(count(transactions, "transaction", "transactions")), backed up \(when)"
    }
}

/// Export, validation and replace-all restore. Validation never touches the store. Restore
/// deletes and inserts in one go, then saves once; if that fails it rolls everything back.
struct BackupService {
    static let maxFileBytes = 50_000_000

    let context: ModelContext
    private let saveAction: (ModelContext) throws -> Void

    init(context: ModelContext, save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context
        self.saveAction = save
    }

    // MARK: Export

    func export(appVersion: String, now: Date = Date()) throws -> Data {
        let wallets = try context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.createdAt)]))
        let categories = try context.fetch(FetchDescriptor<Category>(sortBy: [SortDescriptor(\.createdAt)]))
        let transactions = try context.fetch(FetchDescriptor<Transaction>(sortBy: [SortDescriptor(\.timestamp)]))
        let file = BackupFile(
            formatVersion: BackupFile.currentVersion,
            appVersion: appVersion,
            backupID: UUID(),
            exportedAt: now.timeIntervalSinceReferenceDate,
            wallets: wallets.map {
                BackupWallet(id: $0.id, name: $0.name, emoji: $0.emoji,
                             openingBalanceMinor: $0.openingBalanceMinor, currencyCode: $0.currencyCode,
                             createdAt: $0.createdAt.timeIntervalSinceReferenceDate, isArchived: $0.isArchived)
            },
            categories: categories.map {
                BackupCategory(id: $0.id, name: $0.name, emoji: $0.emoji, colorHex: $0.colorHex,
                               createdAt: $0.createdAt.timeIntervalSinceReferenceDate,
                               updatedAt: $0.updatedAt.timeIntervalSinceReferenceDate, isArchived: $0.isArchived)
            },
            transactions: transactions.map {
                BackupTransaction(id: $0.id, amountMinor: $0.amountMinor, kindRaw: $0.kindRaw,
                                  timestamp: $0.timestamp.timeIntervalSinceReferenceDate, note: $0.note,
                                  walletID: $0.walletID, categoryID: $0.categoryID, transferID: $0.transferID)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    // MARK: Validate (no store access)

    private struct Header: Decodable { let formatVersion: Int }

    static func decodeAndValidate(_ data: Data) throws -> (file: BackupFile, summary: BackupSummary) {
        guard data.count <= maxFileBytes else { throw BackupError.tooLarge }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw BackupError.unreadable }
        guard header.formatVersion <= BackupFile.currentVersion else { throw BackupError.newerVersion }
        guard header.formatVersion == BackupFile.currentVersion else { throw BackupError.unsupportedVersion }
        guard let file = try? decoder.decode(BackupFile.self, from: data) else { throw BackupError.unreadable }
        try validate(file)
        let summary = BackupSummary(
            wallets: file.wallets.count, categories: file.categories.count,
            transactions: file.transactions.count,
            exportedAt: Date(timeIntervalSinceReferenceDate: file.exportedAt))
        return (file, summary)
    }

    private static func unique(_ ids: [UUID]) -> Bool { Set(ids).count == ids.count }

    private static func validate(_ file: BackupFile) throws {
        func fail(_ detail: String) -> BackupError { .invalid(detail) }

        guard file.exportedAt.isFinite else { throw fail("The date is invalid.") }
        guard file.wallets.contains(where: { !$0.isArchived }) else {
            throw fail("It has no active wallet.")
        }
        guard unique(file.wallets.map(\.id)), unique(file.categories.map(\.id)),
              unique(file.transactions.map(\.id))
        else { throw fail("It contains duplicate records.") }

        var currency: [UUID: String] = [:]
        var balances: [UUID: Int64] = [:]
        for wallet in file.wallets {
            guard !wallet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  wallet.name.count <= 200,
                  Money.isValidCurrencyCode(wallet.currencyCode),
                  wallet.openingBalanceMinor.magnitude <= UInt64(Money.maxInputMinorUnits),
                  wallet.createdAt.isFinite
            else { throw fail("A wallet in it is invalid.") }
            currency[wallet.id] = wallet.currencyCode.uppercased()
            balances[wallet.id] = wallet.openingBalanceMinor
        }

        for category in file.categories {
            guard !category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  category.name.count <= 200,
                  CategoryPalette.normalizedHex(category.colorHex) != nil,
                  category.createdAt.isFinite, category.updatedAt.isFinite
            else { throw fail("A category in it is invalid.") }
        }

        let categoryIDs = Set(file.categories.map(\.id))
        var legsByTransfer: [UUID: [BackupTransaction]] = [:]
        for t in file.transactions {
            guard let kind = TransactionKind(rawValue: t.kindRaw) else { throw BackupError.unknownKind }
            guard currency[t.walletID] != nil else { throw fail("A transaction refers to a missing wallet.") }
            if let categoryID = t.categoryID, !categoryIDs.contains(categoryID) {
                throw fail("A transaction refers to a missing category.")
            }
            guard t.timestamp.isFinite else { throw fail("A transaction date is invalid.") }
            do {
                try Transaction.validate(
                    amountMinor: t.amountMinor, kind: kind, categoryID: t.categoryID,
                    transferID: t.transferID, note: t.note)
            } catch {
                throw fail("A transaction in it is invalid.")
            }
            if let transferID = t.transferID { legsByTransfer[transferID, default: []].append(t) }
            let delta: Int64 = (kind == .income || kind == .transferIn) ? t.amountMinor : -t.amountMinor
            let (result, overflow) = (balances[t.walletID] ?? 0).addingReportingOverflow(delta)
            guard !overflow else { throw fail("A wallet balance would be too large.") }
            balances[t.walletID] = result
        }

        for legs in legsByTransfer.values {
            guard legs.count == 2,
                  let out = legs.first(where: { $0.kindRaw == TransactionKind.transferOut.rawValue }),
                  let inn = legs.first(where: { $0.kindRaw == TransactionKind.transferIn.rawValue }),
                  out.walletID != inn.walletID,
                  out.amountMinor == inn.amountMinor,
                  out.timestamp == inn.timestamp,
                  out.note == inn.note,
                  currency[out.walletID] == currency[inn.walletID]
            else { throw fail("A transfer in it is incomplete or inconsistent.") }
        }
    }

    // MARK: Restore (replace all)

    /// Validates again, then replaces every wallet, category and transaction in one save.
    /// On any failure the context is rolled back and the seeder flag is left alone.
    func restore(data: Data, defaults: UserDefaults = .standard) throws {
        let (file, _) = try Self.decodeAndValidate(data)
        guard !context.hasChanges else { throw BackupError.unsavedChanges }
        do {
            for wallet in try context.fetch(FetchDescriptor<Wallet>()) { context.delete(wallet) }
            for category in try context.fetch(FetchDescriptor<Category>()) { context.delete(category) }
            for transaction in try context.fetch(FetchDescriptor<Transaction>()) { context.delete(transaction) }

            for w in file.wallets {
                context.insert(Wallet(
                    id: w.id, name: w.name, emoji: w.emoji, openingBalanceMinor: w.openingBalanceMinor,
                    currencyCode: w.currencyCode, createdAt: Date(timeIntervalSinceReferenceDate: w.createdAt),
                    isArchived: w.isArchived))
            }
            for c in file.categories {
                context.insert(Category(
                    id: c.id, name: c.name, emoji: c.emoji, colorHex: c.colorHex,
                    createdAt: Date(timeIntervalSinceReferenceDate: c.createdAt),
                    updatedAt: Date(timeIntervalSinceReferenceDate: c.updatedAt), isArchived: c.isArchived))
            }
            for t in file.transactions {
                guard let kind = TransactionKind(rawValue: t.kindRaw) else { throw BackupError.unknownKind }
                context.insert(Transaction(
                    id: t.id, amountMinor: t.amountMinor, kind: kind,
                    timestamp: Date(timeIntervalSinceReferenceDate: t.timestamp), note: t.note,
                    walletID: t.walletID, categoryID: t.categoryID, transferID: t.transferID))
            }
            try saveAction(context)
        } catch {
            context.rollback()
            throw BackupError.saveFailed
        }
        // Only after a successful save, so the seeder can never add default records on top.
        defaults.set(true, forKey: DefaultDataSeeder.seededKey)
    }
}
