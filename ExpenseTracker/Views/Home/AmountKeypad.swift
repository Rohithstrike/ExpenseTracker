import SwiftUI

struct AmountKeypad: View {
    let decimalSeparator: Character
    let allowsDecimal: Bool
    let onDigit: (Int) -> Void
    let onDecimal: () -> Void
    let onBackspace: () -> Void

    @ScaledMetric(relativeTo: .title) private var keyHeight: CGFloat = 54

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(1...9, id: \.self) { digit in
                key(label: "\(digit)", action: { onDigit(digit) }) {
                    Text("\(digit)")
                }
            }
            key(label: "Decimal point", enabled: allowsDecimal, action: onDecimal) {
                Text(String(decimalSeparator))
            }
            key(label: "0", action: { onDigit(0) }) {
                Text("0")
            }
            key(label: "Delete", action: onBackspace) {
                Image(systemName: "delete.left")
            }
        }
    }

    private func key<Content: View>(
        label: String,
        enabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .font(.title.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: keyHeight)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(KeyPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

/// Press feedback without motion: only a brief dimming.
private struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
