// ExpenseTracker/RootTabView.swift  (replaces existing contents)
import SwiftUI
import SwiftData

enum AppTab: Hashable, CaseIterable {
    case home, categories, progress, wallets, settings

    var title: String {
        switch self {
        case .home: "Home"
        case .categories: "Categories"
        case .progress: "Progress"
        case .wallets: "Wallets"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .categories: "square.grid.2x2"
        case .progress: "chart.pie"
        case .wallets: "creditcard"
        case .settings: "gearshape"
        }
    }
}

struct RootTabView: View {
    @State private var selection: AppTab = .home

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                NavigationStack {
                    switch tab {
                    case .home:
                        HomeView()
                    case .wallets:
                        WalletsView()
                    default:
                        PlaceholderScreen(tab: tab)
                    }
                }
                .tabItem {
                    Label(tab.title, systemImage: tab.symbol)
                }
                .tag(tab)
            }
        }
        .tint(AppTheme.accent)
        .foregroundStyle(AppTheme.primaryText)
    }
}

private struct PlaceholderScreen: View {
    let tab: AppTab

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: tab.symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)

            Text(tab.title)
                .font(.title2.weight(.semibold))

            Text("Coming in a later phase")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background.ignoresSafeArea())
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(
                reduceMotion ? nil : .easeOut(duration: 0.25)
            ) {
                appeared = true
            }
        }
        .navigationTitle(tab.title)
    }
}

#Preview {
    RootTabView()
        .modelContainer(for: [Wallet.self, Category.self, Transaction.self], inMemory: true)
}
