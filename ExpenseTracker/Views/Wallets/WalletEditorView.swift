// ExpenseTracker/Views/Wallets/WalletEditorView.swift  (new file)
import SwiftUI
import SwiftData

enum WalletEditorMode: Identifiable {
    case create
    case edit(Wallet)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let wallet): wallet.id.uuidString
        }
    }
}

struct WalletEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let mode: WalletEditorMode

    @State private var name: String
    @State private var emoji: String
    @State private var currencyCode: String
    @State private var openingText: String
    @State private var hasTransactions = false
    @State private var errorMessage: String?
    @State private var isSaving = false

    private static let suggestions = ["💵", "🏦", "💳", "👛", "🪙", "🐷", "💰", "📱"]

    private static var decimalSeparator: Character {
        Locale.current.decimalSeparator?.first ?? "."
    }

    init(mode: WalletEditorMode) {
        self.mode = mode
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _emoji = State(initialValue: WalletService.defaultEmoji)
            _currencyCode = State(initialValue: "INR")
            _openingText = State(initialValue: "")
        case .edit(let wallet):
            _name = State(initialValue: wallet.name)
            _emoji = State(initialValue: wallet.emoji)
            _currencyCode = State(initialValue: wallet.currencyCode)
            _openingText = State(initialValue: WalletFormInput.text(
                forOpeningBalance: wallet.openingBalanceMinor,
                currencyCode: wallet.currencyCode,
                decimalSeparator: Self.decimalSeparator
            ))
        }
    }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    private var currencyOptions: [String] {
        var list = WalletFormInput.currencyChoices
        if !list.contains(currencyCode) { list.insert(currencyCode, at: 0) }
        return list
    }

    private var canSave: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Wallet name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Wallet name")
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
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(currencyOptions, id: \.self) { code in
                            Text(code).tag(code)
                        }
                    }
                    .disabled(hasTransactions)
                } header: {
                    Text("Currency")
                } footer: {
                    Text(hasTransactions
                         ? "The currency can't change once a wallet has transactions."
                         : "It is locked as soon as the wallet has its first transaction.")
                }
                .listRowBackground(AppTheme.surface)

                Section {
                    TextField("0", text: $openingText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Opening balance")
                } header: {
                    Text("Opening balance")
                } footer: {
                    Text(isCreate
                         ? "The money in this wallet today. Use a minus sign if it is overdrawn."
                         : "Changing this changes the wallet's current balance. Past transactions are not affected.")
                }
                .listRowBackground(AppTheme.surface)

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.expense)
                    }
                    .listRowBackground(AppTheme.surface)
                }

                if case .edit(let wallet) = mode {
                    Section {
                        Button(wallet.isArchived ? "Restore wallet" : "Archive wallet") {
                            toggleArchive(wallet)
                        }
                    } footer: {
                        Text(wallet.isArchived
                             ? "Restoring makes this wallet available for new transactions again."
                             : "Archived wallets keep their transactions and balance. You can restore them later.")
                    }
                    .listRowBackground(AppTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle(isCreate ? "New Wallet" : "Edit Wallet")
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
            .onAppear { loadLockState() }
            .onChange(of: name) { _, newValue in
                if newValue.count > WalletService.maxNameLength {
                    name = String(newValue.prefix(WalletService.maxNameLength))
                }
                errorMessage = nil
            }
            .onChange(of: emoji) { _, newValue in
                if newValue.count > 1 { emoji = String(newValue.suffix(1)) }
                errorMessage = nil
            }
            .onChange(of: openingText) { _, _ in errorMessage = nil }
            .onChange(of: currencyCode) { _, _ in errorMessage = nil }
        }
        .presentationBackground(AppTheme.background)
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Self.suggestions, id: \.self) { item in
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

    // MARK: Actions (all rules live in WalletService)

    private func loadLockState() {
        guard case .edit(let wallet) = mode else { return }
        let id = wallet.id
        let count = (try? modelContext.fetchCount(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.walletID == id })
        )) ?? 0
        hasTransactions = count > 0
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        do {
            let input = try WalletFormInput.makeInput(
                name: name,
                emoji: emoji,
                openingBalanceText: openingText,
                currencyCode: currencyCode,
                decimalSeparator: Self.decimalSeparator
            )
            let service = WalletService(context: modelContext)
            switch mode {
            case .create:
                try service.create(input)
            case .edit(let wallet):
                try service.update(wallet, with: input)
            }
            AccessibilityNotification.Announcement(isCreate ? "Wallet added" : "Wallet saved").post()
            dismiss()
        } catch {
            fail(message(for: error))
        }
    }

    private func toggleArchive(_ wallet: Wallet) {
        let service = WalletService(context: modelContext)
        do {
            if wallet.isArchived {
                try service.unarchive(wallet)
            } else {
                try service.archive(wallet)
            }
            let word = wallet.isArchived ? "archived" : "restored"
            AccessibilityNotification.Announcement("\(wallet.name) \(word)").post()
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
        switch error {
        case let error as WalletFormError: return error.userMessage
        case let error as WalletError: return error.userMessage
        default: return "The wallet couldn't be saved. Please try again."
        }
    }
}

extension WalletFormError {
    var userMessage: String {
        switch self {
        case .invalidFormat:
            "Enter the opening balance as a number, like 5000 or -250.50."
        case .tooManyDecimals:
            "That's too many decimal places for this currency."
        case .tooLarge:
            "The opening balance is too large."
        case .invalidCurrency:
            "Choose a valid currency."
        }
    }
}

#Preview("New wallet") {
    WalletEditorView(mode: .create)
        .modelContainer(for: [Wallet.self, Category.self, Transaction.self], inMemory: true)
}
