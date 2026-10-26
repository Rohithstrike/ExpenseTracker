import SwiftUI
import SwiftData

/// Home hosts the entry form under a custom header. All form logic lives in
/// EntryView and EntryFormModel.
struct HomeView: View {
    var body: some View {
        VStack(spacing: 0) {
            header
            EntryView()
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Home")
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            Text("Home")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(
                        AppTheme.surface,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

#Preview {
    NavigationStack { HomeView() }
        .modelContainer(for: [Wallet.self, Category.self, Transaction.self], inMemory: true)
}
