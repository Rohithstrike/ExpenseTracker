import SwiftUI
import SwiftData

/// Home hosts the entry form. All form logic lives in EntryView and EntryFormModel.
struct HomeView: View {
    var body: some View {
        EntryView()
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { HomeView() }
        .modelContainer(for: [Wallet.self, Category.self, Transaction.self], inMemory: true)
}
