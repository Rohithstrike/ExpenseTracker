import SwiftUI
import SwiftData

/// The entry form for Expense, Income and Transfer. It only displays the model and
/// forwards taps; every rule lives in EntryFormModel and the services.
struct EntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var model = EntryFormModel(
        snapshot: EntrySnapshot(wallets: [], categories: []),
        decimalSeparator: Locale.current.decimalSeparator?.first ?? "."
    )
    @State private var hasLoaded = false
    @State private var loadFailed = false
    @State private var isSubmitting = false
    @State private var failureMessage: String?
    @State private var saveCount = 0
    @State private var showSuccess = false

    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 52

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.snapshot.wallets.isEmpty {
                ContentUnavailableView {
                    Label(loadFailed ? "Couldn't load your wallets" : "No wallet available",
                          systemImage: loadFailed ? "exclamationmark.triangle" : "creditcard")
                } description: {
                    Text(loadFailed ? "Please try again." : "Wallet setup arrives in a later update.")
                } actions: {
                    if loadFailed { Button("Try again") { reload() } }
                }
            } else {
                form
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .overlay(alignment: .top) {
            if showSuccess { successBanner }
        }
        .sensoryFeedback(.success, trigger: saveCount)
        .onAppear { reload() }
        .task(id: saveCount) {
            guard saveCount > 0 else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showSuccess = true }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showSuccess = false }
        }
    }

    private var form: some View {
        let issue = model.validate().issue
        return ScrollView {
            VStack(spacing: 16) {
                Picker("Type", selection: modeBinding) {
                    ForEach(EntryMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                amountDisplay
                fields
                keypad
                saveSection(issue: issue)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var amountDisplay: some View {
        let sign = model.mode == .income ? "+" : (model.mode == .expense ? "−" : "")
        let signColor = model.mode == .income ? AppTheme.income : AppTheme.expense
        return VStack(spacing: 6) {
            (Text(sign).foregroundStyle(signColor)
                + Text("\(model.currencySymbol)\(model.amount.displayText)"))
                .font(.system(size: amountSize, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Amount")
                .accessibilityValue("\(model.mode.title), \(model.amount.displayText) \(model.currencyCode)")

            if let line = model.contextLine {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button("Clear") { edit { $0.amount.clear() } }
                .font(.footnote)
                .disabled(model.amount.isEmpty)
                .accessibilityLabel("Clear amount")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: Fields (one grouped surface)

    private var fields: some View {
        VStack(spacing: 0) {
            fromRow
            if model.showsDestination {
                divider
                toRow
            }
            if model.showsCategory {
                divider
                categoryRow
            }
            divider
            dateRow
            divider
            noteRow
        }
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var divider: some View {
        Divider().padding(.leading, 14)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Text(title).foregroundStyle(.secondary)
            if !stacked { Spacer(minLength: 8) }
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).lineLimit(1).foregroundStyle(.primary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var fromRow: some View {
        row(model.mode.walletLabel) {
            Menu {
                Picker(model.mode.walletLabel, selection: fromBinding) {
                    ForEach(model.snapshot.wallets) { wallet in
                        Text("\(wallet.emoji) \(wallet.name)").tag(Optional(wallet.id))
                    }
                }
            } label: {
                menuLabel("\(model.fromWallet?.emoji ?? "") \(model.fromWallet?.name ?? "None")")
            }
            .accessibilityLabel(model.mode.walletLabel)
            .accessibilityValue(model.fromWallet?.name ?? "None")
        }
    }

    @ViewBuilder
    private var toRow: some View {
        switch model.transferAvailability {
        case .available:
            row("To") {
                Menu {
                    Picker("To", selection: toBinding) {
                        ForEach(model.destinationOptions) { wallet in
                            Text("\(wallet.emoji) \(wallet.name)").tag(Optional(wallet.id))
                        }
                    }
                } label: {
                    menuLabel("\(model.toWallet?.emoji ?? "") \(model.toWallet?.name ?? "Choose")")
                }
                .accessibilityLabel("To")
                .accessibilityValue(model.toWallet?.name ?? "None chosen")
            }
        case .needsSecondWallet:
            row("To") { Text(EntryIssue.needsSecondWallet.message).font(.footnote) }
        case .noWalletInSameCurrency(let code):
            row("To") { Text(EntryIssue.noWalletInSameCurrency(code).message).font(.footnote) }
        }
    }

    private var categoryRow: some View {
        row(model.categoryIsRequired ? "Category" : "Category (optional)") {
            Menu {
                Picker("Category", selection: categoryBinding) {
                    if !model.categoryIsRequired {
                        Text("None").tag(UUID?.none)
                    }
                    ForEach(model.snapshot.categories) { category in
                        Text("\(category.emoji) \(category.name)").tag(Optional(category.id))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if let category = model.category {
                        Circle().fill(Color(hex: category.colorHex)).frame(width: 8, height: 8)
                        menuLabel("\(category.emoji) \(category.name)")
                    } else {
                        menuLabel("Choose")
                    }
                }
            }
            .accessibilityLabel("Category")
            .accessibilityValue(model.category?.name ?? "None chosen")
        }
    }

    private var dateRow: some View {
        row("Date") {
            HStack(spacing: 8) {
                DatePicker(
                    "Date",
                    selection: dateBinding,
                    in: TransactionService.earliestDate...Date(),
                    displayedComponents: .date
                )
                .labelsHidden()
                if model.date != nil {
                    Button("Today") { edit { $0.setDate(nil) } }
                        .font(.footnote)
                }
            }
        }
    }

    private var noteRow: some View {
        TextField("Add a note (optional)", text: noteBinding, axis: .vertical)
            .lineLimit(1...3)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityLabel("Note")
    }

    // MARK: Keypad and Save

    private var keypad: some View {
        AmountKeypad(
            decimalSeparator: model.amount.decimalSeparator,
            allowsDecimal: model.amount.allowsDecimal,
            onDigit: { digit in edit { $0.amount.appendDigit(digit) } },
            onDecimal: { edit { $0.amount.appendDecimal() } },
            onBackspace: { edit { $0.amount.backspace() } }
        )
    }

    private func saveSection(issue: EntryIssue?) -> some View {
        let canSave = issue == nil && !isSubmitting
        return VStack(spacing: 10) {
            if let failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.expense)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let issue {
                Text(issue.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: save) {
                Text(model.buttonTitle)
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
            .accessibilityHint(issue?.message ?? "")
        }
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

    // MARK: Bindings (every change goes through the model's own setters)

    private var modeBinding: Binding<EntryMode> {
        Binding(get: { model.mode }, set: { new in edit { $0.setMode(new) } })
    }
    private var fromBinding: Binding<UUID?> {
        Binding(get: { model.fromWallet?.id }, set: { id in edit { $0.setFromWallet(id) } })
    }
    private var toBinding: Binding<UUID?> {
        Binding(get: { model.toWallet?.id }, set: { id in edit { $0.setToWallet(id) } })
    }
    private var categoryBinding: Binding<UUID?> {
        Binding(get: { model.category?.id }, set: { id in edit { $0.setCategory(id) } })
    }
    private var dateBinding: Binding<Date> {
        Binding(get: { model.date ?? Date() }, set: { new in edit { $0.setDate(new) } })
    }
    private var noteBinding: Binding<String> {
        Binding(get: { model.note }, set: { text in edit { $0.setNote(text) } })
    }

    // MARK: Actions

    /// Any user edit clears an old failure message.
    private func edit(_ change: (inout EntryFormModel) -> Void) {
        failureMessage = nil
        change(&model)
    }

    private func reload() {
        do {
            model.apply(snapshot: try EntrySnapshot.load(from: modelContext))
            loadFailed = false
        } catch {
            loadFailed = model.snapshot.wallets.isEmpty
        }
        hasLoaded = true
    }

    private func save() {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        switch EntryFormSubmit(context: modelContext).submit(&model) {
        case .saved:
            failureMessage = nil
            saveCount += 1
            AccessibilityNotification.Announcement("Saved").post()
        case .blocked(let issue):
            failureMessage = issue.message
            AccessibilityNotification.Announcement(issue.message).post()
        case .failed(let message):
            failureMessage = message
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

@MainActor
private func entryPreviewContainer() -> ModelContainer {
    let container = try! AppDataStore.makeContainer(inMemory: true)
    let context = container.mainContext
    let wallets = WalletService(context: context)
    _ = try? wallets.create(WalletInput(name: "Cash", openingBalanceMinor: 100_000))
    _ = try? wallets.create(WalletInput(name: "Bank", openingBalanceMinor: 50_000))
    context.insert(Category(name: "Food", emoji: "🍔", colorHex: "#F97316"))
    context.insert(Category(name: "Fuel", emoji: "⛽", colorHex: "#FBBF24"))
    try? context.save()
    return container
}

#Preview {
    NavigationStack { EntryView() }
        .modelContainer(entryPreviewContainer())
}
