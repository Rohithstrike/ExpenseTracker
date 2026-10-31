import XCTest
import SwiftData
@testable import ExpenseTracker

private typealias Raw = [String: Any]

private func items(_ r: Raw, _ section: String) -> [[String: Any]] { r[section] as? [[String: Any]] ?? [] }

private func field(_ r: Raw, _ section: String, _ i: Int, _ key: String) -> Any? {
    let list = items(r, section)
    return list.indices.contains(i) ? list[i][key] : nil
}

private func edit(_ r: inout Raw, _ section: String, _ i: Int, _ key: String, _ value: Any) {
    var list = items(r, section)
    guard list.indices.contains(i) else { return }
    list[i][key] = value
    r[section] = list
}

private func append(_ r: inout Raw, _ section: String, _ item: [String: Any]) {
    var list = items(r, section)
    list.append(item)
    r[section] = list
}

private func removeItem(_ r: inout Raw, _ section: String, _ i: Int) {
    var list = items(r, section)
    guard list.indices.contains(i) else { return }
    list.remove(at: i)
    r[section] = list
}

@MainActor
final class BackupSecurityTests: XCTestCase {
    private struct Env {
        let container: ModelContainer   // keeps the in-memory store alive
        let context: ModelContext
    }

    private struct Boom: Error {}

    private let w1 = UUID(), w2 = UUID(), wUSD = UUID(), c1 = UUID(), c2 = UUID()

    // MARK: Helpers

    private func makeEnv() throws -> Env {
        let container = try AppDataStore.makeContainer(inMemory: true)
        return Env(container: container, context: ModelContext(container))
    }

    private func freshDefaults() throws -> UserDefaults {
        let suite = "BackupSecurityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A small valid backup written by hand: 3 wallets (one USD), 2 categories (one archived),
    /// 5 transactions including one transfer. Indices: 0 expense, 1 income, 2 USD expense,
    /// 3 transferOut, 4 transferIn.
    private func baseFile() -> BackupFile {
        let now = Date().timeIntervalSinceReferenceDate
        let month = 30.0 * 86_400
        let transferTime = now - 7_200
        return BackupFile(
            formatVersion: 1, appVersion: "1.0", backupID: UUID(), exportedAt: now,
            wallets: [
                BackupWallet(id: w1, name: "Cash", emoji: "💵", openingBalanceMinor: 100_000,
                             currencyCode: "INR", createdAt: now - month, isArchived: false),
                BackupWallet(id: w2, name: "Bank", emoji: "🏦", openingBalanceMinor: 500_000,
                             currencyCode: "INR", createdAt: now - month, isArchived: false),
                BackupWallet(id: wUSD, name: "Dollars", emoji: "💲", openingBalanceMinor: 10_000,
                             currencyCode: "USD", createdAt: now - month, isArchived: false)
            ],
            categories: [
                BackupCategory(id: c1, name: "Food", emoji: "🍔", colorHex: "#F97316",
                               createdAt: now - month, updatedAt: now - month, isArchived: false),
                BackupCategory(id: c2, name: "Fuel", emoji: "⛽", colorHex: "#FBBF24",
                               createdAt: now - month, updatedAt: now - month, isArchived: true)
            ],
            transactions: [
                BackupTransaction(id: UUID(), amountMinor: 12_345, kindRaw: "expense", timestamp: now - 3_600,
                                  note: "Lunch", walletID: w1, categoryID: c1, transferID: nil),
                BackupTransaction(id: UUID(), amountMinor: 50_000, kindRaw: "income", timestamp: now - 5_400,
                                  note: "", walletID: w2, categoryID: nil, transferID: nil),
                BackupTransaction(id: UUID(), amountMinor: 2_500, kindRaw: "expense", timestamp: now - 9_000,
                                  note: "", walletID: wUSD, categoryID: c2, transferID: nil),
                BackupTransaction(id: UUID(), amountMinor: 20_000, kindRaw: "transferOut", timestamp: transferTime,
                                  note: "Move", walletID: w1, categoryID: nil, transferID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
                BackupTransaction(id: UUID(), amountMinor: 20_000, kindRaw: "transferIn", timestamp: transferTime,
                                  note: "Move", walletID: w2, categoryID: nil, transferID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
            ])
    }

    private func encode(_ file: BackupFile) throws -> Data { try JSONEncoder().encode(file) }

    private func baseRaw() throws -> Raw {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try encode(baseFile())) as? Raw)
    }

    private func data(_ raw: Raw) throws -> Data { try JSONSerialization.data(withJSONObject: raw) }

    /// Distinctive existing data, so any change to it is noticed.
    private func populate(_ env: Env) throws {
        let wallets = WalletService(context: env.context)
        let cash = try wallets.create(WalletInput(name: "Cash", openingBalanceMinor: 50_000))
        let bank = try wallets.create(WalletInput(name: "Bank", emoji: "🏦", openingBalanceMinor: 100_000))
        let categories = CategoryService(context: env.context)
        let fuel = try categories.create(CategoryInput(name: "Fuel", emoji: "⛽", colorHex: "#FBBF24"))
        _ = try categories.create(CategoryInput(name: "Food", emoji: "🍔", colorHex: "#F97316"))
        let txns = TransactionService(context: env.context)
        _ = try txns.save(TransactionDraft(kind: .expense, amountMinor: 12_345, walletID: cash.id,
                                           categoryID: fuel.id, note: "Full tank"))
        _ = try txns.save(TransactionDraft(kind: .income, amountMinor: 60_000, walletID: bank.id, note: "Pay"))
        _ = try TransferService(context: env.context).save(
            TransferDraft(fromWalletID: bank.id, toWalletID: cash.id, amountMinor: 20_000, note: "Move"))
    }

    private func snapshot(_ context: ModelContext) throws -> [String] {
        var lines: [String] = []
        for w in try context.fetch(FetchDescriptor<Wallet>()) {
            lines.append("W|\(w.id)|\(w.name)|\(w.emoji)|\(w.openingBalanceMinor)|\(w.currencyCode)|\(w.createdAt.timeIntervalSinceReferenceDate)|\(w.isArchived)")
        }
        for c in try context.fetch(FetchDescriptor<ExpenseTracker.Category>()) {
            lines.append("C|\(c.id)|\(c.name)|\(c.emoji)|\(c.colorHex)|\(c.createdAt.timeIntervalSinceReferenceDate)|\(c.updatedAt.timeIntervalSinceReferenceDate)|\(c.isArchived)")
        }
        for t in try context.fetch(FetchDescriptor<Transaction>()) {
            lines.append("T|\(t.id)|\(t.amountMinor)|\(t.kindRaw)|\(t.timestamp.timeIntervalSinceReferenceDate)|\(t.note)|\(t.walletID)|\(String(describing: t.categoryID))|\(String(describing: t.transferID))")
        }
        return lines.sorted()
    }

    private func isInvalid(_ error: BackupError) -> Bool {
        if case .invalid = error { return true }
        return false
    }

    /// The core security check: the bad file is refused by validation AND by restore, and the
    /// existing stored data, the seeder flag and the context are exactly as before.
    private func assertRejected(
        _ name: String, _ bytes: Data, limits: BackupLimits = .standard,
        expect: (BackupError) -> Bool = { if case .invalid = $0 { return true }; return false },
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let env = try makeEnv()
        try populate(env)
        let before = try snapshot(env.context)
        let defaults = try freshDefaults()
        defaults.set(false, forKey: DefaultDataSeeder.seededKey)

        XCTAssertThrowsError(try BackupService.decodeAndValidate(bytes, limits: limits), name, file: file, line: line) {
            XCTAssertTrue(($0 as? BackupError).map(expect) ?? false, "\(name): unexpected error \($0)", file: file, line: line)
        }
        XCTAssertThrowsError(
            try BackupService(context: env.context, limits: limits).restore(data: bytes, defaults: defaults),
            name, file: file, line: line)
        XCTAssertEqual(try snapshot(env.context), before, "\(name): stored data changed", file: file, line: line)
        XCTAssertFalse(defaults.bool(forKey: DefaultDataSeeder.seededKey), "\(name): flag set", file: file, line: line)
        XCTAssertFalse(env.context.hasChanges, "\(name): pending changes", file: file, line: line)
    }

    private func rejectAll(_ cases: [(String, (inout Raw) -> Void)], expect: @escaping (BackupError) -> Bool) throws {
        for (name, mutate) in cases {
            var raw = try baseRaw()
            mutate(&raw)
            try assertRejected(name, try data(raw), expect: expect)
        }
    }

    private func tempFile(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Limits and arithmetic

    func testLimitsAreCentralAndMatchTheRequirements() {
        let l = BackupLimits.standard
        XCTAssertEqual(l.maxFileBytes, 30_000_000)
        XCTAssertEqual(l.maxWallets, 500)
        XCTAssertEqual(l.maxCategories, 500)
        XCTAssertEqual(l.maxTransactions, 60_000)
        XCTAssertEqual(l.maxNameCharacters, 100)
        XCTAssertEqual(l.maxNameBytes, 400)
        XCTAssertEqual(l.maxEmojiBytes, 32)
        XCTAssertEqual(l.maxNoteCharacters, Transaction.maxNoteLength)
        XCTAssertEqual(l.maxNoteBytes, 16_384)
        XCTAssertEqual(BackupService.maxFileBytes, l.maxFileBytes)
    }

    func testSumOfMagnitudesDetectsOverflow() {
        XCTAssertEqual(BackupService.sumMagnitudes([5, -7, 3]), 15)
        XCTAssertEqual(BackupService.sumMagnitudes([]), 0)
        XCTAssertEqual(BackupService.sumMagnitudes([Int64.max / 2, Int64.max / 2]), Int64.max - 1)
        XCTAssertNil(BackupService.sumMagnitudes([Int64.max, 1]))
        XCTAssertNil(BackupService.sumMagnitudes([Int64.max / 2 + 1, Int64.max / 2 + 1]))
        XCTAssertNil(BackupService.sumMagnitudes([Int64.min]))
        XCTAssertNil(BackupService.sumMagnitudes([Int64.min, Int64.max]))
    }

    // MARK: Bounded reading

    func testBoundedReadReturnsAValidFileExactly() throws {
        let bytes = try encode(baseFile())
        XCTAssertEqual(try BackupService.readBounded(from: try tempFile(bytes)), bytes)
    }

    func testBoundedReadEnforcesTheLimitAtTheBoundary() throws {
        var limits = BackupLimits.standard
        limits.maxFileBytes = 100
        XCTAssertEqual(try BackupService.readBounded(from: try tempFile(Data(count: 100)), limits: limits).count, 100)
        for size in [101, 5_000] {
            XCTAssertThrowsError(try BackupService.readBounded(from: try tempFile(Data(count: size)), limits: limits)) {
                XCTAssertEqual($0 as? BackupError, .tooLarge, "\(size) bytes")
            }
        }
        // More than one read chunk, to exercise the loop.
        limits.maxFileBytes = 3_000_000
        XCTAssertEqual(try BackupService.readBounded(from: try tempFile(Data(count: 2_500_000)), limits: limits).count, 2_500_000)
        XCTAssertThrowsError(try BackupService.readBounded(from: try tempFile(Data(count: 3_000_001)), limits: limits)) {
            XCTAssertEqual($0 as? BackupError, .tooLarge)
        }
    }

    func testBoundedReadRejectsFoldersAndMissingFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        XCTAssertThrowsError(try BackupService.readBounded(from: folder)) {
            XCTAssertEqual($0 as? BackupError, .notAFile)
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        XCTAssertThrowsError(try BackupService.readBounded(from: missing)) {
            XCTAssertEqual($0 as? BackupError, .unreadable)
        }
    }

    func testAnEmptyFileIsReadButIsNotABackup() throws {
        let bytes = try BackupService.readBounded(from: try tempFile(Data()))
        XCTAssertTrue(bytes.isEmpty)
        try assertRejected("empty file", bytes, expect: { $0 == .unreadable })
    }

    // MARK: Malformed input

    func testGarbageAndTruncatedInputIsUnreadable() throws {
        let valid = try encode(baseFile())
        let inputs: [(String, Data)] = [
            ("text", Data("not json".utf8)), ("array", Data("[]".utf8)), ("object", Data("{}".utf8)),
            ("number", Data("42".utf8)), ("null", Data("null".utf8)),
            ("binary", Data([0xFF, 0xFE, 0x00, 0x01])), ("truncated", Data(valid.prefix(valid.count / 2)))
        ]
        for (name, bytes) in inputs { try assertRejected(name, bytes, expect: { $0 == .unreadable }) }
    }

    func testDeepNestingIsRejectedWithoutCrashing() throws {
        let deep = String(repeating: "[", count: 20_000) + String(repeating: "]", count: 20_000)
        try assertRejected("top-level nesting", Data(deep.utf8), expect: { $0 == .unreadable })

        // Valid backup with a deeply nested unknown key. It may be refused, but must not crash.
        let json = try XCTUnwrap(String(data: try encode(baseFile()), encoding: .utf8))
        let bomb = String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000)
        let spliced = "{\"deep\":" + bomb + "," + json.dropFirst()
        do { _ = try BackupService.decodeAndValidate(Data(spliced.utf8)) } catch {
            XCTAssertEqual(error as? BackupError, .unreadable)
        }
    }

    func testWrongFieldTypesAreUnreadable() throws {
        let cases: [(String, (inout Raw) -> Void)] = [
            ("version as text", { $0["formatVersion"] = "1" }),
            ("wallets not a list", { $0["wallets"] = "x" }),
            ("wallets contain numbers", { $0["wallets"] = [1, 2, 3] }),
            ("name is a number", { edit(&$0, "wallets", 0, "name", 5) }),
            ("name is null", { edit(&$0, "wallets", 0, "name", NSNull()) }),
            ("amount as text", { edit(&$0, "transactions", 0, "amountMinor", "12") }),
            ("amount as fraction", { edit(&$0, "transactions", 0, "amountMinor", 1.5) }),
            ("id not a uuid", { edit(&$0, "wallets", 0, "id", "not-a-uuid") }),
            ("flag as text", { edit(&$0, "wallets", 0, "isArchived", "yes") }),
            ("date as text", { edit(&$0, "transactions", 0, "timestamp", "now") }),
            ("date missing", { r in
                var list = items(r, "transactions"); list[0].removeValue(forKey: "timestamp"); r["transactions"] = list })
        ]
        try rejectAll(cases, expect: { $0 == .unreadable })
    }

    func testVersionHandling() throws {
        for (version, expected) in [(0, BackupError.unsupportedVersion), (-1, .unsupportedVersion),
                                    (2, .newerVersion), (Int.max, .newerVersion)] {
            var raw = try baseRaw()
            raw["formatVersion"] = version
            try assertRejected("version \(version)", try data(raw), expect: { $0 == expected })
        }
    }

    func testOversizedDataAndExcessRecordCountsAreRejected() throws {
        var small = BackupLimits.standard
        small.maxFileBytes = 200
        try assertRejected("oversized data", try encode(baseFile()), limits: small, expect: { $0 == .tooLarge })

        for (name, change) in [("wallets", { (l: inout BackupLimits) in l.maxWallets = 2 }),
                               ("categories", { (l: inout BackupLimits) in l.maxCategories = 1 }),
                               ("transactions", { (l: inout BackupLimits) in l.maxTransactions = 4 })] {
            var limits = BackupLimits.standard
            change(&limits)
            try assertRejected("too many \(name)", try encode(baseFile()), limits: limits)
        }
    }

    // MARK: Record rules

    func testWalletRejections() throws {
        let byteBomb = "a" + String(repeating: "\u{0301}", count: 200)   // one character, 401 bytes
        let cases: [(String, (inout Raw) -> Void)] = [
            ("blank name", { edit(&$0, "wallets", 0, "name", "   ") }),
            ("name over 100 characters", { edit(&$0, "wallets", 0, "name", String(repeating: "a", count: 101)) }),
            ("name over 400 bytes", { edit(&$0, "wallets", 0, "name", byteBomb) }),
            ("name with control character", { edit(&$0, "wallets", 0, "name", "Ca\u{0007}sh") }),
            ("name with bidi override", { edit(&$0, "wallets", 0, "name", "Ca\u{202E}sh") }),
            ("name with newline", { edit(&$0, "wallets", 0, "name", "Ca\nsh") }),
            ("empty emoji", { edit(&$0, "wallets", 0, "emoji", "") }),
            ("emoji over 32 bytes", { edit(&$0, "wallets", 0, "emoji", String(repeating: "😀", count: 9)) }),
            ("emoji with bidi override", { edit(&$0, "wallets", 0, "emoji", "\u{202E}") }),
            ("currency too short", { edit(&$0, "wallets", 0, "currencyCode", "RS") }),
            ("currency too long", { edit(&$0, "wallets", 0, "currencyCode", "INR1") }),
            ("currency with digits", { edit(&$0, "wallets", 0, "currencyCode", "12A") }),
            ("currency not ASCII", { edit(&$0, "wallets", 0, "currencyCode", "ÀBC") }),
            ("opening balance too large", { edit(&$0, "wallets", 0, "openingBalanceMinor", Money.maxInputMinorUnits + 1) }),
            ("opening balance Int64.min", { edit(&$0, "wallets", 0, "openingBalanceMinor", Int64.min) }),
            ("no active wallet", { r in for i in 0..<3 { edit(&r, "wallets", i, "isArchived", true) } }),
            ("no wallets", { $0["wallets"] = [[String: Any]]() })
        ]
        try rejectAll(cases, expect: isInvalid)
    }

    func testCategoryRejections() throws {
        let cases: [(String, (inout Raw) -> Void)] = [
            ("blank name", { edit(&$0, "categories", 0, "name", " ") }),
            ("name over 100 characters", { edit(&$0, "categories", 0, "name", String(repeating: "b", count: 101)) }),
            ("name with control character", { edit(&$0, "categories", 0, "name", "Fo\u{0000}od") }),
            ("name with bidi isolate", { edit(&$0, "categories", 0, "name", "Fo\u{2067}od") }),
            ("empty emoji", { edit(&$0, "categories", 0, "emoji", "") }),
            ("emoji over 32 bytes", { edit(&$0, "categories", 0, "emoji", String(repeating: "😀", count: 9)) }),
            ("colour word", { edit(&$0, "categories", 0, "colorHex", "red") }),
            ("colour too short", { edit(&$0, "categories", 0, "colorHex", "#12345") }),
            ("colour not hex", { edit(&$0, "categories", 0, "colorHex", "#GGGGGG") }),
            ("colour empty", { edit(&$0, "categories", 0, "colorHex", "") })
        ]
        try rejectAll(cases, expect: isInvalid)
    }

    func testTransactionRejections() throws {
        let noteBomb = "a" + String(repeating: "\u{0301}", count: 9_000)   // one character, over 16 KB
        let cases: [(String, (inout Raw) -> Void)] = [
            ("zero amount", { edit(&$0, "transactions", 0, "amountMinor", 0) }),
            ("negative amount", { edit(&$0, "transactions", 0, "amountMinor", -5) }),
            ("amount over the limit", { edit(&$0, "transactions", 0, "amountMinor", Money.maxInputMinorUnits + 1) }),
            ("amount Int64.max", { edit(&$0, "transactions", 0, "amountMinor", Int64.max) }),
            ("amount Int64.min", { edit(&$0, "transactions", 0, "amountMinor", Int64.min) }),
            ("note over 500 characters", { edit(&$0, "transactions", 0, "note", String(repeating: "a", count: 501)) }),
            ("note over 16 KB", { edit(&$0, "transactions", 0, "note", noteBomb) }),
            ("note with control character", { edit(&$0, "transactions", 0, "note", "a\u{0007}b") }),
            ("note with bidi override", { edit(&$0, "transactions", 0, "note", "a\u{202E}b") }),
            ("expense with a transfer id", { edit(&$0, "transactions", 0, "transferID", UUID().uuidString) })
        ]
        try rejectAll(cases, expect: isInvalid)
    }

    func testDateRejections() throws {
        let earliest = TransactionService.earliestDate.timeIntervalSinceReferenceDate
        let farFuture = Date().timeIntervalSinceReferenceDate + 3 * 86_400
        let cases: [(String, (inout Raw) -> Void)] = [
            ("export date huge", { $0["exportedAt"] = 1e15 }),
            ("export date before 2000", { $0["exportedAt"] = earliest - 1 }),
            ("export date in the future", { $0["exportedAt"] = farFuture }),
            ("wallet date huge", { edit(&$0, "wallets", 0, "createdAt", 1e15) }),
            ("wallet date before 2000", { edit(&$0, "wallets", 0, "createdAt", earliest - 1) }),
            ("category date negative huge", { edit(&$0, "categories", 0, "updatedAt", -1e15) }),
            ("transaction date huge", { edit(&$0, "transactions", 0, "timestamp", 1e15) }),
            ("transaction date negative huge", { edit(&$0, "transactions", 0, "timestamp", -1e15) }),
            ("transaction date before 2000", { edit(&$0, "transactions", 0, "timestamp", earliest - 1) }),
            ("transaction date after export", { edit(&$0, "transactions", 0, "timestamp", farFuture) })
        ]
        try rejectAll(cases, expect: isInvalid)
    }

    func testDuplicateIdentifierRejections() throws {
        let cases: [(String, (inout Raw) -> Void)] = [
            ("duplicate wallet id", { r in if let id = field(r, "wallets", 0, "id") { edit(&r, "wallets", 1, "id", id) } }),
            ("duplicate wallet id in another case", { r in
                if let id = field(r, "wallets", 0, "id") as? String { edit(&r, "wallets", 1, "id", id.lowercased()) } }),
            ("duplicate category id", { r in if let id = field(r, "categories", 0, "id") { edit(&r, "categories", 1, "id", id) } }),
            ("duplicate transaction id", { r in if let id = field(r, "transactions", 0, "id") { edit(&r, "transactions", 1, "id", id) } }),
            ("wallet and category share an id", { r in if let id = field(r, "categories", 0, "id") { edit(&r, "wallets", 2, "id", id) } })
        ]
        try rejectAll(cases, expect: isInvalid)
    }

    func testReferenceRejections() throws {
        let cases: [(String, (inout Raw) -> Void)] = [
            ("missing wallet", { edit(&$0, "transactions", 0, "walletID", UUID().uuidString) }),
            ("missing category", { edit(&$0, "transactions", 0, "categoryID", UUID().uuidString) })
        ]
        try rejectAll(cases, expect: isInvalid)
    }

    func testTransferRejections() throws {
        let cases: [(String, (inout Raw) -> Void)] = [
            ("orphan leg", { removeItem(&$0, "transactions", 4) }),
            ("two out legs", { edit(&$0, "transactions", 4, "kindRaw", "transferOut") }),
            ("two in legs", { edit(&$0, "transactions", 3, "kindRaw", "transferIn") }),
            ("three legs", { r in
                var leg = items(r, "transactions")[3]; leg["id"] = UUID().uuidString; append(&r, "transactions", leg) }),
            ("transfer id reused by a second pair", { r in
                var a = items(r, "transactions")[3], b = items(r, "transactions")[4]
                a["id"] = UUID().uuidString; b["id"] = UUID().uuidString
                append(&r, "transactions", a); append(&r, "transactions", b) }),
            ("both legs in one wallet", { r in
                if let id = field(r, "transactions", 3, "walletID") { edit(&r, "transactions", 4, "walletID", id) } }),
            ("amount mismatch", { edit(&$0, "transactions", 4, "amountMinor", 20_001) }),
            ("time mismatch", { r in
                let t = field(r, "transactions", 4, "timestamp") as? Double ?? 0
                edit(&r, "transactions", 4, "timestamp", t + 1) }),
            ("note mismatch", { edit(&$0, "transactions", 4, "note", "Other") }),
            ("currency mismatch", { r in
                if let id = field(r, "wallets", 2, "id") { edit(&r, "transactions", 4, "walletID", id) } }),
            ("leg with a category", { r in
                if let id = field(r, "categories", 0, "id") { edit(&r, "transactions", 3, "categoryID", id) } }),
            ("leg without a transfer id", { edit(&$0, "transactions", 3, "transferID", NSNull()) })
        ]
        try rejectAll(cases, expect: isInvalid)
    }

    func testUnknownKindsAreRejected() throws {
        for kind in ["refund", "EXPENSE", "", " expense", "transfer"] {
            var raw = try baseRaw()
            edit(&raw, "transactions", 0, "kindRaw", kind)
            try assertRejected("kind '\(kind)'", try data(raw), expect: { $0 == .unknownKind })
        }
    }

    // MARK: Legitimate data must still restore

    func testLegitimateUnicodeIsAcceptedAndStoredExactly() throws {
        var raw = try baseRaw()
        edit(&raw, "wallets", 0, "name", "खर्चा")
        edit(&raw, "wallets", 1, "name", "مصروفات")
        edit(&raw, "wallets", 2, "name", "Café ☕")
        edit(&raw, "categories", 0, "name", "Familie 👨‍👩‍👧")
        edit(&raw, "categories", 0, "emoji", "👨‍👩‍👧")
        edit(&raw, "transactions", 0, "note", "Lunch\nwith\tteam")
        let env = try makeEnv()
        try BackupService(context: env.context).restore(data: try data(raw), defaults: try freshDefaults())
        let names = Set(try env.context.fetch(FetchDescriptor<Wallet>()).map(\.name))
        XCTAssertEqual(names, ["खर्चा", "مصروفات", "Café ☕"])
        let food = try XCTUnwrap(try env.context.fetch(FetchDescriptor<ExpenseTracker.Category>()).first { $0.id == c1 })
        XCTAssertEqual(food.name, "Familie 👨‍👩‍👧")
        XCTAssertEqual(food.emoji, "👨‍👩‍👧")
        let note = try XCTUnwrap(try env.context.fetch(FetchDescriptor<Transaction>()).first { $0.amountMinor == 12_345 })
        XCTAssertEqual(note.note, "Lunch\nwith\tteam")
    }

    func testBoundaryValuesAreAccepted() throws {
        let earliest = TransactionService.earliestDate.timeIntervalSinceReferenceDate
        var raw = try baseRaw()
        edit(&raw, "wallets", 0, "name", String(repeating: "a", count: 100))
        edit(&raw, "wallets", 0, "emoji", String(repeating: "😀", count: 8))
        edit(&raw, "wallets", 0, "createdAt", earliest)
        edit(&raw, "wallets", 1, "openingBalanceMinor", -Money.maxInputMinorUnits)
        edit(&raw, "transactions", 0, "note", String(repeating: "a", count: 500))
        edit(&raw, "transactions", 0, "timestamp", earliest)
        edit(&raw, "transactions", 1, "amountMinor", Money.maxInputMinorUnits)
        let env = try makeEnv()
        XCTAssertNoThrow(try BackupService(context: env.context).restore(data: try data(raw), defaults: try freshDefaults()))
        XCTAssertEqual(try env.context.fetchCount(FetchDescriptor<Transaction>()), 5)
    }

    func testPaddedColoursAreNormalisedOnRestore() throws {
        var raw = try baseRaw()
        edit(&raw, "categories", 0, "colorHex", " #f97316 ")
        let env = try makeEnv()
        try BackupService(context: env.context).restore(data: try data(raw), defaults: try freshDefaults())
        let food = try XCTUnwrap(try env.context.fetch(FetchDescriptor<ExpenseTracker.Category>()).first { $0.id == c1 })
        XCTAssertEqual(food.colorHex, "#F97316")
    }

    func testUnknownKeysAreIgnored() throws {
        var raw = try baseRaw()
        raw["syncToken"] = "future"
        edit(&raw, "wallets", 0, "extra", ["nested": [1, 2, 3]])
        edit(&raw, "transactions", 0, "extra", "x")
        let checked = try BackupService.decodeAndValidate(try data(raw))
        XCTAssertEqual(checked.summary.wallets, 3)
        XCTAssertEqual(checked.summary.transactions, 5)
    }

    // MARK: Restore integrity

    func testSameDeviceRestoreAndRepeatRestoreChangeNothing() throws {
        let env = try makeEnv()
        try populate(env)
        let before = try snapshot(env.context)
        let backup = try BackupService(context: env.context).export(appVersion: "1.0")
        let defaults = try freshDefaults()
        try BackupService(context: env.context).restore(data: backup, defaults: defaults)
        XCTAssertEqual(try snapshot(env.context), before)
        try BackupService(context: env.context).restore(data: backup, defaults: defaults)
        XCTAssertEqual(try snapshot(env.context), before)
    }

    func testBalancesAgreeWithTheLedgerWhateverTheOrder() throws {
        var reversed = try baseRaw()
        reversed["transactions"] = Array(items(reversed, "transactions").reversed())
        let expected: [UUID: Int64] = [w1: 100_000 - 12_345 - 20_000, w2: 500_000 + 50_000 + 20_000, wUSD: 10_000 - 2_500]
        for (name, raw) in [("file order", try baseRaw()), ("reversed order", reversed)] {
            let env = try makeEnv()
            try BackupService(context: env.context).restore(data: try data(raw), defaults: try freshDefaults())
            let service = WalletBalanceService(context: env.context)
            for wallet in try env.context.fetch(FetchDescriptor<Wallet>()) {
                XCTAssertEqual(try service.balance(of: wallet).minorUnits, expected[wallet.id], "\(name) \(wallet.name)")
            }
        }
    }

    func testFailedPersistenceKeepsDataAutosaveAndFlag() throws {
        let env = try makeEnv()
        try populate(env)
        let before = try snapshot(env.context)
        let autosave = env.context.autosaveEnabled
        let defaults = try freshDefaults()
        defaults.set(false, forKey: DefaultDataSeeder.seededKey)
        let failing = BackupService(context: env.context, save: { _ in throw Boom() })
        XCTAssertThrowsError(try failing.restore(data: try encode(baseFile()), defaults: defaults)) {
            XCTAssertEqual($0 as? BackupError, .saveFailed)
        }
        XCTAssertEqual(try snapshot(env.context), before)
        XCTAssertEqual(env.context.autosaveEnabled, autosave)
        XCTAssertFalse(env.context.hasChanges)
        XCTAssertFalse(defaults.bool(forKey: DefaultDataSeeder.seededKey))
    }

    func testSuccessfulRestoreSetsTheFlagAndKeepsAutosave() throws {
        let env = try makeEnv()
        try populate(env)
        let autosave = env.context.autosaveEnabled
        let defaults = try freshDefaults()
        try BackupService(context: env.context).restore(data: try encode(baseFile()), defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: DefaultDataSeeder.seededKey))
        XCTAssertEqual(env.context.autosaveEnabled, autosave)
        XCTAssertEqual(try env.context.fetchCount(FetchDescriptor<Wallet>()), 3)
        XCTAssertEqual(try env.context.fetchCount(FetchDescriptor<Transaction>()), 5)
    }

    func testPendingChangesBlockRestore() throws {
        let env = try makeEnv()
        try populate(env)
        env.context.insert(Wallet(name: "Unsaved"))
        let defaults = try freshDefaults()
        XCTAssertThrowsError(try BackupService(context: env.context).restore(data: try encode(baseFile()), defaults: defaults)) {
            XCTAssertEqual($0 as? BackupError, .unsavedChanges)
        }
        XCTAssertFalse(defaults.bool(forKey: DefaultDataSeeder.seededKey))
    }
}
