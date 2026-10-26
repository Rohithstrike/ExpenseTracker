import SwiftUI

/// One transaction in the history. All wording comes from HistoryFormatting; this view
/// only lays it out. The wallet name is deliberately absent: the group heading has it.
struct TransactionRowView: View {
    let row: HistoryRow
    let currencyCode: String
    let formatting: HistoryFormatting

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            iconTile
            textAndAmount
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(formatting.accessibilityLabel(for: row, currencyCode: currencyCode))
    }

    // MARK: Pieces

    private var iconTile: some View {
        let icon = formatting.icon(for: row)
        return ZStack {
            switch icon {
            case .emoji(let emoji):
                Text(emoji).font(.title3)
            case .transferOut:
                Image(systemName: "arrow.up.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
            case .transferIn:
                Image(systemName: "arrow.down.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.warning)
            }
        }
        .frame(width: tileSize, height: tileSize)
        .background(tileColor(for: icon), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }

    private func tileColor(for icon: HistoryIcon) -> Color {
        switch icon {
        case .emoji:
            return row.categoryColorHex.map { Color(hex: $0).opacity(0.18) } ?? AppTheme.accentSoft
        case .transferOut, .transferIn:
            return AppTheme.accentSoft
        case .warning:
            return AppTheme.warning.opacity(0.18)
        }
    }

    private var textAndAmount: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            titleBlock
            if !stacked { Spacer(minLength: 8) }
            amount
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formatting.title(for: row))
                .font(.body.weight(.medium))
                .lineLimit(2)
            if let subtitle = formatting.subtitle(for: row) {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)
            }
        }
    }

    private var amount: some View {
        Text(formatting.amountText(for: row, currencyCode: currencyCode))
            .font(.body.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(amountColor)
    }

    private var amountColor: Color {
        switch formatting.amountStyle(for: row) {
        case .income: return AppTheme.income
        case .expense: return AppTheme.expense
        case .transfer: return AppTheme.primaryText
        }
    }
}
