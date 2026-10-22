// ExpenseTracker/ExpenseTrackerApp.swift  (replaces existing contents)
import SwiftUI
import SwiftData

@main
struct ExpenseTrackerApp: App {
    private let container: ModelContainer?

    init() {
        do {
            let created = try AppDataStore.makeContainer()
            // If seeding fails, Home shows an empty state instead of crashing.
            try? DefaultDataSeeder.seedIfNeeded(context: created.mainContext)
            container = created
        } catch {
            // Never fall back to a temporary in-memory store: that would hide data loss.
            container = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                RootTabView()
                    .modelContainer(container)
            } else {
                DataUnavailableView()
            }
        }
    }
}

private struct DataUnavailableView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            Text("Couldn't open your data")
                .font(.title3.weight(.semibold))
            Text("Please force-quit and reopen the app. If this keeps happening, contact support.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background.ignoresSafeArea())
    }
}
