import SwiftUI
import SwiftData

struct CategoriesView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var categories: [Category]

    @State private var alertMessage: String?
    @State private var editorMode: CategoryEditorMode?
    @State private var pendingDelete: Category?

    private var activeCategories: [Category] {
        CategoryService.sorted(categories.filter { !$0.isArchived })
    }
    private var archivedCategories: [Category] {
        CategoryService.sorted(categories.filter { $0.isArchived })
    }
    private var atLimit: Bool {
        activeCategories.count >= CategoryService.maxActiveCategories
    }

    var body: some View {
        Group {
            if categories.isEmpty {
                ContentUnavailableView {
                    Label("No categories", systemImage: "square.grid.2x2")
                } description: {
                    Text("Add a category to organise your spending.")
                } actions: {
                    Button("Add category") { addCategory() }
                }
            } else {
                list
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { addCategory() } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add category")
            }
        }
        .sheet(item: $editorMode) { mode in
            CategoryEditorView(mode: mode)
        }
        .alert("Can't update category", isPresented: alertIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .confirmationDialog(
            "Delete category?", isPresented: deleteIsPresented, titleVisibility: .visible,
            presenting: pendingDelete
        ) { category in
            Button("Delete “\(category.name)”", role: .destructive) { delete(category) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("No transactions use it. Deleting can't be undone.")
        }
    }

    // MARK: List

    private var list: some View {
        List {
            Section {
                ForEach(activeCategories) { category in
                    row(for: category)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { requestDelete(category) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { archive(category) } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.orange)
                        }
                }
            } header: {
                Text("Active")
            } footer: {
                Text(atLimit
                     ? "\(activeCategories.count) of \(CategoryService.maxActiveCategories) active categories. Limit reached: archive one to add another."
                     : "\(activeCategories.count) of \(CategoryService.maxActiveCategories) active categories")
            }

            if !archivedCategories.isEmpty {
                Section {
                    ForEach(archivedCategories) { category in
                        row(for: category)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { requestDelete(category) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { unarchive(category) } label: {
                                    Label("Restore", systemImage: "tray.and.arrow.up")
                                }
                                .tint(AppTheme.accent)
                            }
                    }
                } header: {
                    Text("Archived")
                } footer: {
                    Text("Archived categories stay on past transactions. Restore one to use it again.")
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(for category: Category) -> some View {
        Button {
            editorMode = .edit(category)
        } label: {
            CategoryRow(category: category)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the category editor")
        .listRowBackground(AppTheme.surface)
        .contextMenu {
            Button { editorMode = .edit(category) } label: {
                Label("Edit", systemImage: "pencil")
            }
            if category.isArchived {
                Button { unarchive(category) } label: {
                    Label("Restore", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button { archive(category) } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
            Button(role: .destructive) { requestDelete(category) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: Actions (all rules live in CategoryService)

    private func addCategory() {
        if atLimit {
            alertMessage = CategoryError.categoryLimitReached.message
        } else {
            editorMode = .create
        }
    }

    private func archive(_ category: Category) {
        run(announcement: "\(category.name) archived") {
            try CategoryService(context: modelContext).archive(category)
        }
    }

    private func unarchive(_ category: Category) {
        run(announcement: "\(category.name) restored") {
            try CategoryService(context: modelContext).unarchive(category)
        }
    }

    /// Blocked categories explain why in the existing alert; others ask for confirmation.
    private func requestDelete(_ category: Category) {
        do {
            if let blocker = try CategoryService(context: modelContext).deletionBlocker(for: category) {
                alertMessage = blocker.message
            } else {
                pendingDelete = category
            }
        } catch {
            alertMessage = "The category couldn't be checked. Please try again."
        }
    }

    /// The service re-checks eligibility, so a category that became ineligible shows the alert.
    private func delete(_ category: Category) {
        let name = category.name
        run(announcement: "\(name) deleted") {
            try CategoryService(context: modelContext).delete(category)
        }
    }

    private var deleteIsPresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func run(announcement: String, _ action: () throws -> Void) {
        do {
            try action()
            AccessibilityNotification.Announcement(announcement).post()
        } catch let error as CategoryError {
            alertMessage = error.message
        } catch {
            alertMessage = "The category couldn't be updated. Please try again."
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }
}

// MARK: - Row

private struct CategoryRow: View {
    let category: Category

    @ScaledMetric(relativeTo: .title2) private var badgeSize: CGFloat = 44

    private var colorName: String {
        CategoryPalette.color(forHex: category.colorHex)?.name ?? "custom colour"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(category.emoji)
                .font(.title2)
                .frame(width: badgeSize, height: badgeSize)
                .background(Color(hex: category.colorHex).opacity(0.25), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.headline)
                    .lineLimit(2)
                if category.isArchived {
                    Text("Archived")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Circle()
                .fill(Color(hex: category.colorHex))
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(category.name)\(category.isArchived ? ", archived" : "")")
        .accessibilityValue(colorName)
    }
}

// MARK: - Preview data (debug only)

#if DEBUG
@MainActor
private func sampleCategoriesContainer() -> ModelContainer {
    // Preview only: a failure here cannot affect the shipping app.
    let container = try! AppDataStore.makeContainer(inMemory: true)
    let context = container.mainContext
    context.insert(Category(name: "Fuel", emoji: "⛽", colorHex: "#FBBF24"))
    context.insert(Category(name: "Food", emoji: "🍔", colorHex: "#F97316"))
    context.insert(Category(name: "Shopping", emoji: "🛍️", colorHex: "#EC4899"))
    context.insert(Category(name: "Old gym", emoji: "🏋️", colorHex: "#14B8A6", isArchived: true))
    return container
}

#Preview("Sample categories") {
    NavigationStack { CategoriesView() }
        .modelContainer(sampleCategoriesContainer())
}
#endif
