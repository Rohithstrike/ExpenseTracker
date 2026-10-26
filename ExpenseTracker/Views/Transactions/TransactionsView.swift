import SwiftUI
import SwiftData

/// The Transactions screen: history for a chosen period, grouped by day and then wallet.
/// It only displays TransactionsViewModel; every rule lives in the model and services.
struct TransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var model: TransactionsViewModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Transactions")
        .onAppear {
            // Entries are saved on Home, so every appearance re-reads the store.
            if let model {
                model.reload()
            } else {
                model = TransactionsViewModel(context: modelContext)
            }
        }
    }

    // MARK: Content

    private func content(_ model: TransactionsViewModel) -> some View {
        VStack(spacing: 12) {
            filters(model)
                .padding(.horizontal)
            switch model.state {
            case .loaded:
                history(model)
            case .empty:
                ContentUnavailableView(
                    model.emptyTitle,
                    systemImage: "list.bullet.rectangle",
                    description: Text(model.emptyDetail)
                )
                .frame(maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load transactions", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { model.reload() }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func history(_ model: TransactionsViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(model.days) { day in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.formatting.dayTitle(for: day.day))
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        ForEach(day.wallets) { group in
                            walletSection(group, model)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .refreshable { model.reload() }
    }

    private func walletSection(_ group: WalletHistory, _ model: TransactionsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.formatting.walletHeading(group))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 66) }
                    TransactionRowView(
                        row: row,
                        currencyCode: group.currencyCode,
                        formatting: model.formatting)
                }
            }
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: Filters

    private func filters(_ model: TransactionsViewModel) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            periodMenu(model)
            walletMenu(model)
        }
    }

    private func periodMenu(_ model: TransactionsViewModel) -> some View {
        let binding = Binding<HistoryPeriod>(
            get: { model.period },
            set: { model.selectPeriod($0) })
        return Menu {
            Picker("Period", selection: binding) {
                ForEach(HistoryPeriod.allCases, id: \.self) { period in
                    Text(model.formatting.periodTitle(period)).tag(period)
                }
            }
        } label: {
            filterLabel(title: "Period", value: model.periodTitle)
        }
        .accessibilityLabel("Period")
        .accessibilityValue(model.periodTitle)
    }

    private func walletMenu(_ model: TransactionsViewModel) -> some View {
        let binding = Binding<UUID?>(
            get: { model.selectedWalletID },
            set: { model.selectWallet($0) })
        return Menu {
            Picker("Wallet", selection: binding) {
                Text(HistoryFormatting.allWalletsTitle).tag(UUID?.none)
                ForEach(model.walletOptions) { option in
                    Text("\(option.emoji) \(option.name)\(option.isArchived ? " (archived)" : "")")
                        .tag(Optional(option.id))
                }
            }
        } label: {
            filterLabel(title: "Wallet", value: model.walletFilterTitle)
        }
        .accessibilityLabel("Wallet")
        .accessibilityValue(model.walletFilterTitle)
    }

    private func filterLabel(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.primary)
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: Previews (in-memory store; your real data is never touched)

@MainActor
private func transactionsPreviewContainer() -> ModelContainer {
    let container = try! AppDataStore.makeContainer(inMemory: true)
    let context = container.mainContext
    let wallets = WalletService(context: context)
    guard let iob = try? wallets.create(WalletInput(name: "IOB", emoji: "🏦", openingBalanceMinor: 1_000_000)),
          let sbi = try? wallets.create(WalletInput(name: "SBI", emoji: "💳", openingBalanceMinor: 500_000))
    else { return container }

    let fuel = Category(name: "Fuel", emoji: "⛽", colorHex: "#FBBF24")
    let food = Category(name: "Food", emoji: "🍔", colorHex: "#F97316")
    let retired = Category(name: "Retired", emoji: "🧺", colorHex: "#A78BFA")
    context.insert(fuel)
    context.insert(food)
    context.insert(retired)
    try? context.save()

    let service = TransactionService(context: context)
    _ = try? service.save(TransactionDraft(
        kind: .expense, amountMinor: 50_000, walletID: iob.id, categoryID: fuel.id, note: "Full tank"))
    _ = try? service.save(TransactionDraft(
        kind: .expense, amountMinor: 20_000, walletID: iob.id, categoryID: food.id, note: "Lunch\nwith team"))
    _ = try? service.save(TransactionDraft(
        kind: .expense, amountMinor: 8_000, walletID: iob.id, categoryID: retired.id))
    retired.isArchived = true
    _ = try? service.save(TransactionDraft(
        kind: .income, amountMinor: 250_000, walletID: sbi.id, note: "Freelance payment"))

    let transfers = TransferService(context: context)
    _ = try? transfers.save(TransferDraft(
        fromWalletID: iob.id, toWalletID: sbi.id, amountMinor: 300_000, note: "Rent share"))
    let broken = TransferDraft(fromWalletID: iob.id, toWalletID: sbi.id, amountMinor: 10_000)
    _ = try? transfers.save(broken)
    if let leg = (try? context.fetch(FetchDescriptor<Transaction>()))?
        .first(where: { $0.transferID == broken.id && $0.kind == .transferIn }) {
        context.delete(leg)
    }
    try? context.save()
    return container
}

#Preview("With data") {
    NavigationStack { TransactionsView() }
        .modelContainer(transactionsPreviewContainer())
}

#Preview("Empty") {
    NavigationStack { TransactionsView() }
        .modelContainer(for: [Wallet.self, Category.self, Transaction.self], inMemory: true)
}
