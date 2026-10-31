import Foundation
import SwiftData

enum BackupError: Error, Equatable {
    case unreadable
    case tooLarge
    case notAFile
    case notDownloaded
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
        case .notAFile:
            return "Choose a backup file, not a folder or another kind of item."
        case .notDownloaded:
            return "This file is stored in iCloud and isn't on this device yet. Open it in the Files app to download it, then try again."
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

/// Every size and count limit in one place, so tests can use small values.
struct BackupLimits: Equatable {
    var maxFileBytes = 30_000_000
    var maxWallets = 4
    var maxCategories = 50
    var maxTransactions = 60_000
    var maxNameCharacters = 100
    var maxNameBytes = 400
    var maxEmojiBytes = 32
    var maxNoteCharacters = 500
    var maxNoteBytes = 16_384
    /// A backup may hold dates at most this long after its own export date.
    var dateSlack: TimeInterval = 2 * 86_400

    static let standard = BackupLimits()
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

/// Export, validation and replace-all restore. A backup file is untrusted input: it is read
/// with a hard size bound, fully validated with no store access, and only then applied in one
/// save. If anything fails the context is rolled back and existing data is left as it was.
struct BackupService {
    static let maxFileBytes = BackupLimits.standard.maxFileBytes

    let context: ModelContext
    let limits: BackupLimits
    private let saveAction: (ModelContext) throws -> Void

    init(
        context: ModelContext,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        limits: BackupLimits = .standard
    ) {
        self.context = context
        self.saveAction = save
        self.limits = limits
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

    // MARK: Reading (bounded)

    /// Reads a picked file without ever holding more than the size limit (plus one byte) in
    /// memory. The reported file size is only a shortcut: a missing size is not treated as
    /// zero, and a file that grows after the check is still stopped by the bounded read.
    static func readBounded(from url: URL, limits: BackupLimits = .standard) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .fileSizeKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { throw BackupError.unreadable }
        if values.isDirectory == true || values.isRegularFile == false { throw BackupError.notAFile }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
            throw BackupError.notDownloaded
        }
        if let size = values.fileSize, size > limits.maxFileBytes { throw BackupError.tooLarge }

        guard let handle = try? FileHandle(forReadingFrom: url) else { throw BackupError.unreadable }
        defer { try? handle.close() }

        var data = Data()
        let chunk = 1_048_576
        while data.count <= limits.maxFileBytes {
            let want = min(chunk, limits.maxFileBytes + 1 - data.count)
            let part: Data?
            do { part = try handle.read(upToCount: want) } catch { throw BackupError.unreadable }
            guard let part, !part.isEmpty else { break }
            data.append(part)
        }
        guard data.count <= limits.maxFileBytes else { throw BackupError.tooLarge }
        return data
    }

    // MARK: Validate (no store access)

    private struct Header: Decodable { let formatVersion: Int }

    static func decodeAndValidate(
        _ data: Data, limits: BackupLimits = .standard, now: Date = Date()
    ) throws -> (file: BackupFile, summary: BackupSummary) {
        guard !data.isEmpty else { throw BackupError.unreadable }
        guard data.count <= limits.maxFileBytes else { throw BackupError.tooLarge }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw BackupError.unreadable }
        guard header.formatVersion <= BackupFile.currentVersion else { throw BackupError.newerVersion }
        guard header.formatVersion == BackupFile.currentVersion else { throw BackupError.unsupportedVersion }
        guard let file = try? decoder.decode(BackupFile.self, from: data) else { throw BackupError.unreadable }
        try validate(file, limits: limits, now: now)
        let summary = BackupSummary(
            wallets: file.wallets.count, categories: file.categories.count,
            transactions: file.transactions.count,
            exportedAt: Date(timeIntervalSinceReferenceDate: file.exportedAt))
        return (file, summary)
    }

    // MARK: Text rules

    private static func isForbidden(_ scalar: Unicode.Scalar, allowLineBreaks: Bool) -> Bool {
        let v = scalar.value
        // Bidirectional overrides and isolates can make text display in a misleading order.
        if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) { return true }
        if scalar.properties.generalCategory == .control {
            return !(allowLineBreaks && (v == 0x09 || v == 0x0A || v == 0x0D))
        }
        return false
    }

    static func isCleanText(_ text: String, allowLineBreaks: Bool) -> Bool {
        !text.unicodeScalars.contains { isForbidden($0, allowLineBreaks: allowLineBreaks) }
    }

    static func isValidName(_ name: String, _ limits: BackupLimits) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.count <= limits.maxNameCharacters
            && name.utf8.count <= limits.maxNameBytes
            && isCleanText(name, allowLineBreaks: false)
    }

    static func isValidEmoji(_ emoji: String, _ limits: BackupLimits) -> Bool {
        !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && emoji.utf8.count <= limits.maxEmojiBytes
            && isCleanText(emoji, allowLineBreaks: false)
    }

    static func isValidNote(_ note: String, _ limits: BackupLimits) -> Bool {
        note.count <= limits.maxNoteCharacters
            && note.utf8.count <= limits.maxNoteBytes
            && isCleanText(note, allowLineBreaks: true)
    }

    /// Sum of absolute values, or nil if it would overflow. Because the sum of magnitudes
    /// fits, every partial balance in any order fits too.
    static func sumMagnitudes(_ values: [Int64]) -> Int64? {
        var total: Int64 = 0
        for value in values {
            guard let magnitude = Int64(exactly: value.magnitude) else { return nil }
            let (next, overflow) = total.addingReportingOverflow(magnitude)
            if overflow { return nil }
            total = next
        }
        return total
    }

    // MARK: Validation

    private static func validate(_ file: BackupFile, limits: BackupLimits, now: Date) throws {
        func fail(_ detail: String) -> BackupError { .invalid(detail) }

        guard file.wallets.count <= limits.maxWallets else {
            throw fail("It has more than \(limits.maxWallets) wallets.")
        }
        guard file.categories.count <= limits.maxCategories else {
            throw fail("It has more than \(limits.maxCategories) categories.")
        }
        guard file.transactions.count <= limits.maxTransactions else {
            throw fail("It has more than \(limits.maxTransactions) transactions.")
        }

        // The app itself never records dates outside this window, so a real backup never has them.
        let earliest = TransactionService.earliestDate.timeIntervalSinceReferenceDate
        let newestExport = now.addingTimeInterval(limits.dateSlack).timeIntervalSinceReferenceDate
        guard file.exportedAt.isFinite, file.exportedAt >= earliest, file.exportedAt <= newestExport else {
            throw fail("Its date isn't valid. Check that this device's date and time are correct.")
        }
        let latest = file.exportedAt + limits.dateSlack
        func dateOK(_ value: Double) -> Bool { value.isFinite && value >= earliest && value <= latest }

        guard file.wallets.contains(where: { !$0.isArchived }) else { throw fail("It has no active wallet.") }

        let walletIDs = Set(file.wallets.map(\.id))
        let categoryIDs = Set(file.categories.map(\.id))
        let transactionIDs = Set(file.transactions.map(\.id))
        guard walletIDs.count == file.wallets.count,
              categoryIDs.count == file.categories.count,
              transactionIDs.count == file.transactions.count,
              walletIDs.isDisjoint(with: categoryIDs)
        else { throw fail("It contains duplicate records.") }

        var currency: [UUID: String] = [:]
        var magnitude: [UUID: Int64] = [:]
        var balance: [UUID: Int64] = [:]
        var currencyTotal: [String: Int64] = [:]
        let tooLarge = fail("The amounts in it are too large.")

        for wallet in file.wallets {
            guard isValidName(wallet.name, limits) else {
                throw fail("A wallet name is empty, too long or has unsupported characters.")
            }
            guard isValidEmoji(wallet.emoji, limits) else { throw fail("A wallet icon isn't valid.") }
            guard Money.isValidCurrencyCode(wallet.currencyCode) else {
                throw fail("A wallet has an invalid currency.")
            }
            guard wallet.openingBalanceMinor.magnitude <= UInt64(Money.maxInputMinorUnits) else {
                throw fail("A wallet's opening balance is out of range.")
            }
            guard dateOK(wallet.createdAt) else { throw fail("A wallet has an invalid date.") }
            let code = wallet.currencyCode.uppercased()
            let opening = Int64(wallet.openingBalanceMinor.magnitude)
            currency[wallet.id] = code
            magnitude[wallet.id] = opening
            balance[wallet.id] = wallet.openingBalanceMinor
            let (sum, overflow) = (currencyTotal[code] ?? 0).addingReportingOverflow(opening)
            guard !overflow else { throw tooLarge }
            currencyTotal[code] = sum
        }

        for category in file.categories {
            guard isValidName(category.name, limits) else {
                throw fail("A category name is empty, too long or has unsupported characters.")
            }
            guard isValidEmoji(category.emoji, limits) else { throw fail("A category icon isn't valid.") }
            guard CategoryPalette.normalizedHex(category.colorHex) != nil else {
                throw fail("A category has an invalid colour.")
            }
            guard dateOK(category.createdAt), dateOK(category.updatedAt) else {
                throw fail("A category has an invalid date.")
            }
        }

        var legsByTransfer: [UUID: [BackupTransaction]] = [:]
        for t in file.transactions {
            guard let kind = TransactionKind(rawValue: t.kindRaw) else { throw BackupError.unknownKind }
            guard let code = currency[t.walletID] else { throw fail("A transaction refers to a missing wallet.") }
            if let categoryID = t.categoryID, !categoryIDs.contains(categoryID) {
                throw fail("A transaction refers to a missing category.")
            }
            guard dateOK(t.timestamp) else { throw fail("A transaction has an invalid date.") }
            guard isValidNote(t.note, limits) else {
                throw fail("A transaction note is too long or has unsupported characters.")
            }
            do {
                try Transaction.validate(
                    amountMinor: t.amountMinor, kind: kind, categoryID: t.categoryID,
                    transferID: t.transferID, note: t.note)
            } catch {
                throw fail("A transaction in it is invalid.")
            }
            if let transferID = t.transferID { legsByTransfer[transferID, default: []].append(t) }

            // Amounts are positive here. Summing magnitudes first makes the order irrelevant.
            let (walletSum, o1) = (magnitude[t.walletID] ?? 0).addingReportingOverflow(t.amountMinor)
            let (currencySum, o2) = (currencyTotal[code] ?? 0).addingReportingOverflow(t.amountMinor)
            guard !o1, !o2 else { throw tooLarge }
            magnitude[t.walletID] = walletSum
            currencyTotal[code] = currencySum
            let delta = (kind == .income || kind == .transferIn) ? t.amountMinor : -t.amountMinor
            let (next, o3) = (balance[t.walletID] ?? 0).addingReportingOverflow(delta)
            guard !o3 else { throw tooLarge }
            balance[t.walletID] = next
        }

        for legs in legsByTransfer.values {
            guard legs.count == 2,
                  let out = legs.first(where: { $0.kindRaw == TransactionKind.transferOut.rawValue }),
                  let inn = legs.first(where: { $0.kindRaw == TransactionKind.transferIn.rawValue }),
                  out.walletID != inn.walletID,
                  out.amountMinor == inn.amountMinor,
                  out.timestamp == inn.timestamp,
                  out.note == inn.note,
                  out.categoryID == nil, inn.categoryID == nil,
                  currency[out.walletID] == currency[inn.walletID]
            else { throw fail("A transfer in it is incomplete or inconsistent.") }
        }
    }

    // MARK: Restore (replace all)

    /// Validates again, then replaces every wallet, category and transaction in one save.
    /// On any failure the context is rolled back and the seeder flag is left alone.
    func restore(data: Data, defaults: UserDefaults = .standard, now: Date = Date()) throws {
        let (file, _) = try Self.decodeAndValidate(data, limits: limits, now: now)
        guard !context.hasChanges else { throw BackupError.unsavedChanges }

        // Nothing may be written between the deletes and the single save below.
        let autosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosave }

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
                    id: c.id, name: c.name, emoji: c.emoji,
                    colorHex: CategoryPalette.normalizedHex(c.colorHex) ?? c.colorHex,
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
        } catch let error as BackupError {
            context.rollback()
            throw error
        } catch {
            context.rollback()
            throw BackupError.saveFailed
        }
        // Only after a successful save, so the seeder can never add default records on top.
        defaults.set(true, forKey: DefaultDataSeeder.seededKey)
    }
}
