import SwiftUI
import SwiftData

enum CategoryEditorMode: Identifiable {
    case create
    case edit(Category)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let category): category.id.uuidString
        }
    }
}

/// Quick picks shown under the emoji field. Each must pass the service's emoji rule.
enum CategoryEmojiSuggestions {
    static let all = ["🍽️", "🚌", "🛒", "🎬", "💡", "🎓", "🏥", "✈️", "🐶", "🎁"]
}

struct CategoryEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let mode: CategoryEditorMode

    @State private var name: String
    @State private var emoji: String
    @State private var colorHex: String
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var colorTouched = false
    @State private var duplicateNote: String?

    @ScaledMetric(relativeTo: .title2) private var swatchSize: CGFloat = 40

    init(mode: CategoryEditorMode) {
        self.mode = mode
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _emoji = State(initialValue: CategoryService.defaultEmoji)
            _colorHex = State(initialValue: CategoryPalette.defaultColor.hex)
        case .edit(let category):
            _name = State(initialValue: category.name)
            _emoji = State(initialValue: category.emoji)
            _colorHex = State(initialValue:
                CategoryPalette.normalizedHex(category.colorHex) ?? category.colorHex)
        }
    }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    /// In create mode no colour counts as chosen until the user picks one.
    private var hasColor: Bool { !isCreate || colorTouched }

    private var canSave: Bool {
        !isSaving && hasColor && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                Section("Preview") {
                    preview
                }
                .listRowBackground(AppTheme.surface)

                Section("Name") {
                    TextField("Category name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Category name")
                }
                .listRowBackground(AppTheme.surface)

                Section {
                    TextField("Emoji", text: $emoji)
                        .font(.largeTitle)
                        .multilineTextAlignment(.center)
                        .accessibilityLabel("Emoji")
                        .accessibilityHint("Use the emoji keyboard to choose one emoji")
                    suggestionRow
                } header: {
                    Text("Emoji")
                } footer: {
                    Text("Tap the globe key on your keyboard to switch to the emoji keyboard, or pick one below.")
                }
                .listRowBackground(AppTheme.surface)

                Section {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: swatchSize + 14), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(CategoryPalette.colors) { option in swatch(option) }
                        customCell
                    }
                    .padding(.vertical, 6)

                    if let duplicateNote {
                        Label(duplicateNote, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.warning)
                    }
                } header: {
                    Text("Colour")
                } footer: {
                    Text(hasColor
                         ? "The colour is used for this category wherever it appears."
                         : "Choose a colour to continue.")
                }
                .listRowBackground(AppTheme.surface)

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.expense)
                    }
                    .listRowBackground(AppTheme.surface)
                }

                if case .edit(let category) = mode {
                    Section {
                        Button(category.isArchived ? "Restore category" : "Archive category") {
                            toggleArchive(category)
                        }
                    } footer: {
                        Text(category.isArchived
                             ? "Restoring makes this category available for new transactions again."
                             : "Archived categories stay on past transactions. You can restore them later.")
                    }
                    .listRowBackground(AppTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle(isCreate ? "New Category" : "Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreate ? "Add" : "Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onChange(of: name) { _, newValue in
                if newValue.count > CategoryService.maxNameLength {
                    name = String(newValue.prefix(CategoryService.maxNameLength))
                }
                errorMessage = nil
            }
            .onChange(of: emoji) { _, newValue in
                if newValue.count > 1 { emoji = String(newValue.suffix(1)) }
                errorMessage = nil
            }
            .onChange(of: colorHex) { _, _ in
                errorMessage = nil
                refreshDuplicateNote()
            }
            .onAppear { refreshDuplicateNote() }
        }
        .presentationBackground(AppTheme.background)
    }

    // MARK: Pieces

    private var previewColor: Color { hasColor ? Color(hex: colorHex) : Color.gray }

    private var previewDescription: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let shownName = trimmed.isEmpty ? "no name yet" : trimmed
        let colourName = hasColor
            ? (CategoryPalette.color(forHex: colorHex)?.name ?? "custom colour")
            : "no colour chosen"
        return "Preview: \(shownName), \(colourName)"
    }

    private var preview: some View {
        HStack(spacing: 12) {
            Text(emoji.isEmpty ? CategoryService.defaultEmoji : emoji)
                .font(.title2)
                .frame(width: swatchSize + 4, height: swatchSize + 4)
                .background(previewColor.opacity(0.25), in: Circle())
            Text(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Category name" : name)
                .font(.headline)
                .lineLimit(2)
            Spacer(minLength: 8)
            Circle()
                .fill(previewColor)
                .frame(width: 14, height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(previewDescription)
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(CategoryEmojiSuggestions.all, id: \.self) { item in
                    Button {
                        emoji = item
                    } label: {
                        Text(item)
                            .font(.title2)
                            .padding(8)
                            .background(
                                emoji == item ? AppTheme.accent.opacity(0.25) : Color.clear,
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use \(item)")
                    .accessibilityAddTraits(emoji == item ? .isSelected : [])
                }
            }
        }
    }

    private var customBinding: Binding<Color> {
        Binding(
            get: { hasColor ? Color(hex: colorHex) : Color.gray },
            set: { newColor in
                guard let hex = CategoryColorHex.hex(from: newColor) else { return }
                colorTouched = true
                colorHex = hex
                refreshDuplicateNote()
            }
        )
    }

    private var customCell: some View {
        let isCustom = CategoryPalette.color(forHex: colorHex) == nil
        return ColorPicker("Custom colour", selection: customBinding, supportsOpacity: false)
            .labelsHidden()
            .frame(width: swatchSize, height: swatchSize)
            .overlay {
                Circle()
                    .strokeBorder(AppTheme.primaryText.opacity(isCustom ? 1 : 0), lineWidth: 2)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel("Custom colour")
            .accessibilityValue(isCustom ? "selected, \(colorHex)" : "not selected")
    }

    /// Informational only: never blocks saving. A new category's untouched default colour is skipped.
    private func refreshDuplicateNote() {
        guard !(isCreate && !colorTouched),
              let hex = CategoryPalette.normalizedHex(colorHex) else {
            duplicateNote = nil
            return
        }
        var excluded: UUID?
        if case .edit(let category) = mode { excluded = category.id }
        let match = try? CategoryService(context: modelContext)
            .activeCategory(usingColorHex: hex, excluding: excluded)
        duplicateNote = match.map { "Another category already uses this exact colour (\($0.name))." }
    }

    private func swatch(_ option: CategoryColor) -> some View {
        let selected = hasColor && CategoryPalette.normalizedHex(colorHex) == option.hex
        return Button {
            colorTouched = true
            colorHex = option.hex
            refreshDuplicateNote()
        } label: {
            Circle()
                .fill(Color(hex: option.hex))
                .frame(width: swatchSize, height: swatchSize)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                    }
                }
                .overlay {
                    Circle()
                        .strokeBorder(AppTheme.primaryText.opacity(selected ? 1 : 0), lineWidth: 2)
                        .padding(-4)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Actions (all rules live in CategoryService)

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        do {
            let input = CategoryInput(name: name, emoji: emoji, colorHex: colorHex)
            let service = CategoryService(context: modelContext)
            switch mode {
            case .create:
                try service.create(input)
            case .edit(let category):
                try service.update(category, with: input)
            }
            AccessibilityNotification.Announcement(isCreate ? "Category added" : "Category saved").post()
            dismiss()
        } catch {
            fail(message(for: error))
        }
    }

    private func toggleArchive(_ category: Category) {
        let service = CategoryService(context: modelContext)
        do {
            if category.isArchived {
                try service.unarchive(category)
            } else {
                try service.archive(category)
            }
            let word = category.isArchived ? "archived" : "restored"
            AccessibilityNotification.Announcement("\(category.name) \(word)").post()
            dismiss()
        } catch {
            fail(message(for: error))
        }
    }

    private func fail(_ text: String) {
        errorMessage = text
        isSaving = false
        AccessibilityNotification.Announcement(text).post()
    }

    private func message(for error: Error) -> String {
        if let error = error as? CategoryError { return error.message }
        return "The category couldn't be saved. Please try again."
    }
}

#Preview("New category") {
    CategoryEditorView(mode: .create)
        .modelContainer(for: [Wallet.self, Category.self, Transaction.self], inMemory: true)
}
