import SwiftUI

/// Placeholder until Settings (preferences, export) is built in a later phase.
struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape")
                .font(.system(size: 10, weight: .light))
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)

            Text("Settings")
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
        .navigationTitle("Settings")
    }
}

#Preview {
    NavigationStack { SettingsView() }
}
