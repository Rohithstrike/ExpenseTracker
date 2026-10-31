import SwiftUI
import SwiftData
import Charts

/// The Progress tab: income, expenses and spending by category for a chosen period.
/// It only displays ProgressViewModel; every number comes from the transactions.
struct ProgressOverviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var model: ProgressViewModel?

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
        .navigationTitle("Progress")
        .onAppear {
            // Entries are saved elsewhere, so every appearance re-reads the store.
            if let model {
                model.reload()
            } else {
                model = ProgressViewModel(context: modelContext)
            }
        }
    }

    // MARK: Content

    private func content(_ model: ProgressViewModel) -> some View {
        VStack(spacing: 12) {
            periodMenu(model)
                .padding(.horizontal)
            switch model.state {
            case .loaded:
                if let summary = model.selectedSummary {
                    ScrollView {
                        details(summary, model)
                            .padding(.horizontal)
                            .padding(.bottom, 16)
                    }
                    .refreshable { model.reload() }
                }
            case .empty:
                ContentUnavailableView(
                    "No activity \(model.periodPhrase)",
                    systemImage: "chart.pie",
                    description: Text("Income and spending you record will appear here."))
                    .frame(maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load progress", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { model.reload() }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func details(_ summary: CurrencySummary, _ model: ProgressViewModel) -> some View {
        VStack(spacing: 16) {
            if model.summaries.count > 1 { currencyPicker(model) }
            totals(summary)
            spending(summary)
        }
    }

    // MARK: Pieces

    private func periodMenu(_ model: ProgressViewModel) -> some View {
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
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Period")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(model.periodTitle)
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
        .accessibilityLabel("Period")
        .accessibilityValue(model.periodTitle)
    }

    private func currencyPicker(_ model: ProgressViewModel) -> some View {
        let binding = Binding<String>(
            get: { model.selectedSummary?.currencyCode ?? "" },
            set: { model.selectCurrency($0) })
        return Picker("Currency", selection: binding) {
            ForEach(model.summaries) { summary in
                Text(currencyLabel(summary.currencyCode)).tag(summary.currencyCode)
            }
        }
        .pickerStyle(.segmented)
    }

    private func totals(_ summary: CurrencySummary) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        let code = summary.currencyCode
        return layout {
            card("Income", amount(summary.incomeMinor, code), AppTheme.income)
            card("Expenses", amount(summary.expenseMinor, code), AppTheme.expense)
            card("Net", amount(summary.netMinor, code),
                 summary.netMinor < 0 ? AppTheme.expense : AppTheme.primaryText)
        }
    }

    private func card(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func spending(_ summary: CurrencySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spending by category")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if summary.categories.isEmpty {
                Text("No spending in this period.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                chart(summary)
                VStack(spacing: 0) {
                    ForEach(Array(summary.categories.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 54) }
                        categoryRow(item, summary)
                    }
                }
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func chart(_ summary: CurrencySummary) -> some View {
        Chart(summary.categories) { item in
            SectorMark(
                angle: .value("Spent", Double(item.amountMinor)),
                innerRadius: .ratio(0.62),
                angularInset: 1)
                .foregroundStyle(by: .value("Category", item.id))
        }
        .chartForegroundStyleScale(
            domain: summary.categories.map(\.id),
            range: summary.categories.map { color(for: $0) })
        .chartLegend(.hidden)
        .frame(height: 220)
        // The list below says the same thing in words, with every amount.
        .accessibilityHidden(true)
    }

    private func categoryRow(_ item: CategorySpend, _ summary: CurrencySummary) -> some View {
        let share = summary.expenseMinor > 0 ? Double(item.amountMinor) / Double(summary.expenseMinor) : 0
        let shareText = share.formatted(.percent.precision(.fractionLength(0)))
        let amountText = amount(item.amountMinor, summary.currencyCode)
        return HStack(spacing: 12) {
            Text(item.emoji)
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(color(for: item).opacity(0.25), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.isArchived ? "\(item.name) (archived)" : item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(shareText)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Spacer(minLength: 8)
            Text(amountText)
                .font(.body.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Circle()
                .fill(color(for: item))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(amountText), \(shareText) of spending")
    }

    // MARK: Helpers

    private func color(for item: CategorySpend) -> Color {
        item.colorHex.map { Color(hex: $0) } ?? Color.gray
    }

    private func currencyLabel(_ code: String) -> String {
        code.isEmpty ? "Unknown" : code
    }

    private func amount(_ minor: Int64, _ code: String) -> String {
        let money = Money(minorUnits: minor, currencyCode: code)
        return Money.isValidCurrencyCode(code) ? money.formatted() : money.plainString()
    }
}

#Preview("Empty") {
    NavigationStack { ProgressOverviewView() }
        .modelContainer(for: [Wallet.self, Category.self, Transaction.self], inMemory: true)
}
