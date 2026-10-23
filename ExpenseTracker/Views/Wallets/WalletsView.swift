// ExpenseTracker/Views/Wallets/WalletsView.swift  (replaces checkpoint 2 version)
import SwiftUI
import SwiftData

struct WalletsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Wallet.createdAt) private var wallets: [Wallet]

    @State private var balances: [UUID: Money] = [:]
    @State private var alertMessage: String?
    @State private var editorMode: WalletEditorMode?

    private var activeWallets: [Wallet] { wallets.filter { !$0.isArchived } }
    private var archivedWallets: [Wallet] { wallets.filter { $0.isArchived } }

    var body: some View {
        Group {
            if wallets.isEmpty {
                ContentUnavailableView {
                    Label("No wallets", systemImage: "creditcard")
                } description: {
                    Text("Add a wallet to start tracking where your money is.")
                } actions: {
                    Button("Add wallet") { addWallet() }
                }
            } else {
                list
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Wallets")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { addWallet() } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add wallet")
            }
        }
        .sheet(item: $editorMode, onDismiss: refreshBalances) { mode in
            WalletEditorView(mode: mode)
        }
        .onAppear { refreshBalances() }
        .onChange(of: wallets.count) { _, _ in refreshBalances() }
        .alert("Can't update wallet", isPresented: alertIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: List

    private var list: some View {
        List {
            Section {
                ForEach(activeWallets) { wallet in
                    row(for: wallet)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { archive(wallet) } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.orange)
                        }
                }
            } header: {
                Text("Active")
            } footer: {
                Text("\(activeWallets.count) of \(WalletService.maxActiveWallets) active wallets")
            }

            if !archivedWallets.isEmpty {
                Section {
                    ForEach(archivedWallets) { wallet in
                        row(for: wallet)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { unarchive(wallet) } label: {
                                    Label("Restore", systemImage: "tray.and.arrow.up")
                                }
                                .tint(AppTheme.accent)
                            }
                    }
                } header: {
                    Text("Archived")
                } footer: {
                    Text("Archived wallets keep their transactions and balance. Restore one to use it again.")
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(for wallet: Wallet) -> some View {
        Button {
            editorMode = .edit(wallet)
        } label: {
            WalletRow(wallet: wallet, balance: balances[wallet.id])
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the wallet editor")
        .listRowBackground(AppTheme.surface)
        .contextMenu {
            Button { editorMode = .edit(wallet) } label: {
                Label("Edit", systemImage: "pencil")
            }
            if wallet.isArchived {
                Button { unarchive(wallet) } label: {
                    Label("Restore", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button { archive(wallet) } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
        }
    }

    // MARK: Actions (all rules live in WalletService)

    private func addWallet() {
        if activeWallets.count >= WalletService.maxActiveWallets {
            alertMessage = WalletError.walletLimitReached.userMessage
        } else {
            editorMode = .create
        }
    }

    private func archive(_ wallet: Wallet) {
        run(announcement: "\(wallet.name) archived") {
            try WalletService(context: modelContext).archive(wallet)
        }
    }

    private func unarchive(_ wallet: Wallet) {
        run(announcement: "\(wallet.name) restored") {
            try WalletService(context: modelContext).unarchive(wallet)
        }
    }

    private func run(announcement: String, _ action: () throws -> Void) {
        do {
            try action()
            refreshBalances()
            AccessibilityNotification.Announcement(announcement).post()
        } catch let error as WalletError {
            alertMessage = error.userMessage
        } catch {
            alertMessage = "The wallet couldn't be updated. Please try again."
        }
    }

    /// One wallet failing to calculate shows "—" for that wallet only.
    private func refreshBalances() {
        let service = WalletBalanceService(context: modelContext)
        var result: [UUID: Money] = [:]
        for wallet in wallets {
            if let money = try? service.balance(of: wallet) {
                result[wallet.id] = money
            }
        }
        balances = result
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }
}

// MARK: - Row

private struct WalletRow: View {
    let wallet: Wallet
    let balance: Money?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var badgeSize: CGFloat = 44

    private var balanceText: String { balance?.formatted() ?? "—" }
    private var isNegative: Bool { (balance?.minorUnits ?? 0) < 0 }

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))

        layout {
            HStack(spacing: 12) {
                Text(wallet.emoji)
                    .font(.title2)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(AppTheme.accent.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(wallet.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(wallet.isArchived ? "\(wallet.currencyCode) · Archived" : wallet.currencyCode)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !stacked { Spacer(minLength: 8) }
            Text(balanceText)
                .font(.headline.monospacedDigit())
                .foregroundStyle(isNegative ? AppTheme.expense : Color.primary)
        }
        .padding(.vertical, 4)
        .opacity(wallet.isArchived ? 0.75 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(wallet.name), \(wallet.currencyCode)\(wallet.isArchived ? ", archived" : "")")
        .accessibilityValue(balance == nil ? "Balance unavailable" : "Balance \(balanceText)")
    }
}

// MARK: - Messages

extension WalletError {
    var userMessage: String {
        switch self {
        case .lastActiveWallet:
            "You need at least one active wallet, so this one can't be archived."
        case .walletLimitReached:
            "You can have up to \(WalletService.maxActiveWallets) active wallets. Archive one first."
        case .duplicateName:
            "Another active wallet already uses this name."
        case .invalidName:
            "Enter a name of 1 to \(WalletService.maxNameLength) characters."
        case .invalidEmoji:
            "Choose a single emoji."
        case .invalidOpeningBalance:
            "The opening balance is outside the allowed range."
        case .invalidCurrency:
            "Choose a valid currency."
        case .currencyLocked:
            "The currency can't change once a wallet has transactions."
        }
    }
}

// MARK: - Preview data (debug only)

#if DEBUG
@MainActor
private func sampleWalletsContainer() -> ModelContainer {
    // Preview only: a failure here cannot affect the shipping app.
    let container = try! AppDataStore.makeContainer(inMemory: true)
    let context = container.mainContext
    let cash = Wallet(name: "Cash", emoji: "💵", openingBalanceMinor: 100_000,
                      createdAt: Date(timeIntervalSince1970: 1))
    let bank = Wallet(name: "Bank", emoji: "🏦", openingBalanceMinor: 50_000,
                      createdAt: Date(timeIntervalSince1970: 2))
    let old = Wallet(name: "Old savings", emoji: "🐷", openingBalanceMinor: 250_000,
                     createdAt: Date(timeIntervalSince1970: 3), isArchived: true)
    context.insert(cash)
    context.insert(bank)
    context.insert(old)
    context.insert(Transaction(amountMinor: 60_000, kind: .expense, walletID: bank.id))
    return container
}

#Preview("Sample wallets") {
    NavigationStack { WalletsView() }
        .modelContainer(sampleWalletsContainer())
}
#endif
