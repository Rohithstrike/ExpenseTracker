import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Query(filter: #Predicate<Wallet> { $0.isArchived == false }, sort: \Wallet.createdAt)
    private var wallets: [Wallet]
    @Query(filter: #Predicate<Category> { $0.isArchived == false }, sort: \Category.name)
    private var categories: [Category]
    // Used only for the temporary balance line below.
    @Query private var transactions: [Transaction]

    @State private var kind: TransactionKind = .expense
    @State private var input = AmountInput(
        currencyCode: "INR",
        decimalSeparator: Locale.current.decimalSeparator?.first ?? "."
    )
    @State private var selectedWalletID: UUID?
    @State private var selectedCategoryID: UUID?
    @State private var note = ""
    @State private var draftID = UUID()   // becomes the transaction id: repeat saves cannot duplicate
    @State private var errorMessage: String?
    @State private var saveCount = 0
    @State private var showSuccess = false

    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 52

    // MARK: Derived state

    private var effectiveWallet: Wallet? {
        wallets.first { $0.id == selectedWalletID } ?? wallets.first
    }
    private var selectedCategory: Category? {
        categories.first { $0.id == selectedCategoryID }
    }
    private var currencyCode: String { effectiveWallet?.currencyCode ?? "INR" }
    private var canSave: Bool { effectiveWallet != nil && input.isSavable }
    private var kindTitle: String { kind == .income ? "Income" : "Expense" }

    private var currencySymbol: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        return formatter.currencySymbol ?? currencyCode
    }

    private var balanceText: String {
        guard let wallet = effectiveWallet,
              let money = try? BalanceCalculator.balance(of: wallet, transactions: transactions)
        else { return "—" }
        return money.formatted()
    }

    // MARK: Body

    var body: some View {
        Group {
            if wallets.isEmpty {
                ContentUnavailableView(
                    "No wallet available",
                    systemImage: "creditcard",
                    description: Text("Wallet setup arrives in a later update.")
                )
            } else {
                form
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .overlay(alignment: .top) {
            if showSuccess { successBanner }
        }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: saveCount)
        .task(id: saveCount) {
            guard saveCount > 0 else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showSuccess = true }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showSuccess = false }
        }
        .onChange(of: currencyCode) { _, newCode in input.setCurrency(newCode) }
        .onChange(of: input) { _, _ in errorMessage = nil }
        .onChange(of: selectedCategoryID) { _, _ in errorMessage = nil }
        .onChange(of: note) { _, newValue in
            if newValue.count > Transaction.maxNoteLength {
                note = String(newValue.prefix(Transaction.maxNoteLength))
            }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("\(effectiveWallet?.name ?? "Wallet") balance: \(balanceText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Type", selection: $kind) {
                    Text("Expense").tag(TransactionKind.expense)
                    Text("Income").tag(TransactionKind.income)
                }
                .pickerStyle(.segmented)

                amountDisplay
                chips
                noteField

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.expense)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                AmountKeypad(
                    decimalSeparator: input.decimalSeparator,
                    allowsDecimal: input.allowsDecimal,
                    onDigit: { input.appendDigit($0) },
                    onDecimal: { input.appendDecimal() },
                    onBackspace: { input.backspace() }
                )

                saveButton
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Pieces

    private var amountDisplay: some View {
        let sign = kind == .income ? "+" : "−"
        let signColor = kind == .income ? AppTheme.accent : AppTheme.expense
        return VStack(spacing: 4) {
            (Text(sign).foregroundStyle(signColor) + Text("\(currencySymbol)\(input.displayText)"))
                .font(.system(size: amountSize, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Amount")
                .accessibilityValue("\(kindTitle), \(input.displayText) \(currencyCode)")

            Button("Clear") { input.clear() }
                .font(.footnote)
                .disabled(input.isEmpty)
                .accessibilityLabel("Clear amount")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var chips: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            walletMenu
            categoryMenu
        }
    }

    private var walletMenu: some View {
        let walletBinding = Binding<UUID?>(
            get: { effectiveWallet?.id },
            set: { selectedWalletID = $0 }
        )
        return Menu {
            Picker("Wallet", selection: walletBinding) {
                ForEach(wallets) { wallet in
                    Text("\(wallet.emoji) \(wallet.name)").tag(Optional(wallet.id))
                }
            }
        } label: {
            chip(title: "Wallet", value: effectiveWallet?.name ?? "None") {
                Text(effectiveWallet?.emoji ?? "👛")
            }
        }
        .accessibilityLabel("Wallet")
        .accessibilityValue(effectiveWallet?.name ?? "None")
    }

    private var categoryMenu: some View {
        let categoryBinding = Binding<UUID?>(
            get: { selectedCategory?.id },
            set: { selectedCategoryID = $0 }
        )
        let title = kind == .expense ? "Category" : "Category (optional)"
        return Menu {
            Picker("Category", selection: categoryBinding) {
                Text("None").tag(UUID?.none)
                ForEach(categories) { category in
                    Text("\(category.emoji) \(category.name)").tag(Optional(category.id))
                }
            }
        } label: {
            chip(title: title, value: selectedCategory?.name ?? "Choose") {
                HStack(spacing: 4) {
                    if let category = selectedCategory {
                        Circle().fill(Color(hex: category.colorHex)).frame(width: 8, height: 8)
                        Text(category.emoji)
                    } else {
                        Image(systemName: "tag")
                    }
                }
            }
        }
        .accessibilityLabel("Category")
        .accessibilityValue(selectedCategory?.name ?? "None chosen")
    }

    private func chip<Leading: View>(
        title: String,
        value: String,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(spacing: 8) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.primary)
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var noteField: some View {
        TextField("Add a note (optional)", text: $note, axis: .vertical)
            .lineLimit(1...3)
            .padding(12)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel("Note")
    }

    private var saveButton: some View {
        Button(action: save) {
            Text("Save \(kindTitle)")
                .font(.headline)
                .foregroundStyle(AppTheme.onAccent)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(
                    AppTheme.accent.opacity(canSave ? 1 : 0.35),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
    }

    private var successBanner: some View {
        Label("Saved", systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(AppTheme.surface, in: Capsule())
            .overlay(Capsule().stroke(AppTheme.accent, lineWidth: 1))
            .padding(.top, 8)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    // MARK: Actions

    private func save() {
        guard let wallet = effectiveWallet else { fail("No wallet is available."); return }
        guard let money = input.money, money.minorUnits > 0 else {
            fail("Enter an amount greater than zero.")
            return
        }
        if kind == .expense && selectedCategory == nil {
            fail("Choose a category.")
            return
        }

        let draft = TransactionDraft(
            id: draftID,
            kind: kind,
            amountMinor: money.minorUnits,
            walletID: wallet.id,
            categoryID: selectedCategory?.id,
            note: note
        )

        do {
            try TransactionService(context: modelContext).save(draft)
            draftID = UUID()
            input.clear()
            note = ""
            selectedCategoryID = nil
            errorMessage = nil
            saveCount += 1
            AccessibilityNotification.Announcement("Transaction saved").post()
        } catch {
            if (error as? TransactionValidationError) == .noteTooLong {
                fail("The note is too long.")
            } else {
                fail("Couldn't save. Your entry is still here, so please try again.")
            }
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        AccessibilityNotification.Announcement(message).post()
    }
}

#Preview {
    NavigationStack { HomeView() }
        .modelContainer(for: [Wallet.self, Category.self, Transaction.self], inMemory: true)
}
