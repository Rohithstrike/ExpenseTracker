// ExpenseTracker/Models/SchemaV1.swift  (new file)
import Foundation
import SwiftData

/// Version 1 of the on-disk schema. When a stored property changes after release,
/// add SchemaV2 and a migration stage instead of editing this silently.
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Wallet.self, Category.self, Transaction.self]
    }
}

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// The one place the app (and its tests) create the data store.
enum AppDataStore {
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: ModelConfiguration.CloudKitDatabase.none   // iCloud sync is a 1.1 feature
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: configuration
        )
    }
}
