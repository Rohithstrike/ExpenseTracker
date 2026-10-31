import SwiftUI
import SwiftData

/// Edits one transaction or transfer. It only displays TransactionEditModel and calls the
/// existing services, which enforce every rule.
struct TransactionEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var model: TransactionEditModel
    @State private var errorMessage: String?
    @State private var isSaving = false

    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 44

    init(model: TransactionEditModel) {
        _model = State(initialValue: model)
    }

    private var issue: EditIssue? { model.validate() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !model.isTransfer {
                        Picker("Type", selection: kindBinding) {
                            Text("Expense").tag(TransactionKind.expense)
                            Text("Income").tag(TransactionKind.income)
                        }
                        .pickerStyle(.segmented)
                    }
                    amountDisplay
                    fields
                    AmountKeypad(
                        decimalSeparator: model.amount.decimalSeparator,
                        allowsDecimal: model.amount.allowsDecimal,
                        onDigit: { digit in edit { $0.amount.appendDigit(digit) } },
                        onDecimal: { edit { $0.amount.appendDecimal() } },
                        onBackspace: { edit { $0.amount.backspace() } })
                    messageLine
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle(model.isTransfer ? "Edit Transfer" : "Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || issue != nil)
                }
            }
        }
        .presentationBackground(AppTheme.background)
    }

    // MARK: Pieces

    private var amountDisplay: some View {
        let sign = model.isTransfer ? "" : (model.kind == .income ? "+" : "−")
        let signColor = model.kind == .income ? AppTheme.income : AppTheme.expense
        return (Text(sign).foregroundStyle(signColor)
            + Text("\(model.currencySymbol)\(model.amount.displayText)"))
            .font(.system(size: amountSize, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Amount")
            .accessibilityValue("\(model.amount.displayText) \(model.currencyCode)")
    }

    private var fields: some View {
        VStack(spacing: 0) {
            fieldRow(walletTitle) { walletMenu(walletBinding, model.walletChoices) }
            Divider().padding(.leading, 14)
            if model.isTransfer {
                fieldRow("To") { walletMenu(toBinding, model.destinationChoices) }
            } else {
                fieldRow(model.kind == .expense ? "Category" : "Category (optional)") { categoryMenu }
            }
            Divider().padding(.leading, 14)
            fieldRow("Date") {
                DatePicker(
                    "Date", selection: dateBinding,
                    in: TransactionService.earliestDate...max(Date(), model.date),
                    displayedComponents: .date)
                    .labelsHidden()
            }
            Divider().padding(.leading, 14)
            TextField("Add a note (optional)", text: noteBinding, axis: .vertical)
                .lineLimit(1...3)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityLabel("Note")
        }
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var walletTitle: String {
        if model.isTransfer { return "From" }
        return model.kind == .income ? "Deposit to" : "Paid from"
    }

    private func fieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private func walletMenu(_ selection: Binding<UUID?>, _ choices: [EditWalletOption]) -> some View {
        let current = choices.first { $0.id == selection.wrappedValue }
        return Menu {
            Picker("Wallet", selection: selection) {
                ForEach(choices) { Text($0.label).tag(Optional($0.id)) }
            }
        } label: {
            menuLabel(current?.label ?? "Choose")
        }
        .accessibilityValue(current?.name ?? "None chosen")
    }

    private var categoryMenu: some View {
        let current = model.categoryChoices.first { $0.id == model.categoryID }
        return Menu {
            Picker("Category", selection: categoryBinding) {
                if model.kind != .expense { Text("None").tag(UUID?.none) }
                ForEach(model.categoryChoices) { Text($0.label).tag(Optional($0.id)) }
            }
        } label: {
            menuLabel(current?.label ?? "Choose")
        }
        .accessibilityLabel("Category")
        .accessibilityValue(current?.name ?? "None chosen")
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

    @ViewBuilder
    private var messageLine: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(AppTheme.expense)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let issue {
            Text(issue.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Bindings

    private var kindBinding: Binding<TransactionKind> {
        Binding(get: { model.kind }, set: { new in edit { $0.setKind(new) } })
    }
    private var walletBinding: Binding<UUID?> {
        Binding(get: { model.walletID }, set: { id in edit { $0.setWallet(id) } })
    }
    private var toBinding: Binding<UUID?> {
        Binding(get: { model.toWalletID }, set: { id in edit { $0.setToWallet(id) } })
    }
    private var categoryBinding: Binding<UUID?> {
        Binding(get: { model.categoryID }, set: { id in edit { $0.setCategory(id) } })
    }
    private var dateBinding: Binding<Date> {
        Binding(get: { model.date }, set: { new in edit { $0.setDate(new) } })
    }
    private var noteBinding: Binding<String> {
        Binding(get: { model.note }, set: { text in edit { $0.setNote(text) } })
    }

    // MARK: Actions

    private func edit(_ change: (inout TransactionEditModel) -> Void) {
        errorMessage = nil
        change(&model)
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        do {
            switch model.target {
            case .ordinary(let id):
                guard let edit = model.transactionEdit() else { isSaving = false; return }
                try TransactionService(context: modelContext).update(id: id, to: edit)
            case .transfer(let transferID):
                guard let edit = model.transferEdit() else { isSaving = false; return }
                try TransferService(context: modelContext).update(transferID: transferID, to: edit)
            }
            AccessibilityNotification.Announcement("Saved").post()
            dismiss()
        } catch {
            let wallet = model.walletChoices.first { $0.id == model.walletID }
            let entryWallet = EntryWallet(
                id: model.walletID, name: wallet?.name ?? "this wallet", emoji: wallet?.emoji ?? "",
                currencyCode: model.currencyCode, balanceMinor: 0)
            errorMessage = EntryFormSubmit.message(for: error, wallet: entryWallet)
            isSaving = false
        }
    }
}
