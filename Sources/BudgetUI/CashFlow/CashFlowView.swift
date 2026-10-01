import BudgetCore
import Charts
import SwiftUI

struct CashFlowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            SummaryStrip()
                .padding(.horizontal, 16)
                .padding(.top, 12)
            BalanceChart()
                .frame(height: 150)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            CashFlowGridView()
        }
        .navigationTitle("Cash Flow")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View by", selection: $model.granularity) {
                    ForEach(Granularity.allCases, id: \.self) { granularity in
                        Text(granularity.label).tag(granularity)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.move(by: -model.visibleColumns)
                } label: {
                    Label("Previous Page", systemImage: "chevron.left.2")
                }
                .help("Previous page (⌥⌘[)")
                Button {
                    model.move(by: -1)
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .help("Back one column (⌘[)")
                Button("Today") {
                    model.goToToday()
                }
                .help("Jump to today (⌘T)")
                Button {
                    model.move(by: 1)
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .help("Forward one column (⌘])")
                Button {
                    model.move(by: model.visibleColumns)
                } label: {
                    Label("Next Page", systemImage: "chevron.right.2")
                }
                .help("Next page (⌥⌘])")
            }
        }
    }
}

/// Headline figures above the chart.
struct SummaryStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let projection = model.projection
        let today = projection.ledger(on: projection.today)
        let nextPay = projection.payEvents.first { $0.payDate >= projection.today && $0.state == .planned }
        let estimate = projection.estimates.first { $0.year == projection.today.financialYear }
        HStack(spacing: 10) {
            if let bankBalance = projection.bankBalance {
                StatTile(
                    title: "In Up now",
                    value: Format.money(bankBalance),
                    detail: model.syncStatus == .syncing ? "Syncing…" : syncDetail
                )
            }
            StatTile(
                title: "Balance today",
                value: today?.closing.map(Format.money) ?? "Not set",
                detail: today?.closing == nil ? "Set a balance in the grid" : "After what's still due today"
            )
            if let low = projection.lowestUpcoming, let amount = low.closing {
                StatTile(
                    title: "Lowest ahead",
                    value: Format.money(amount),
                    detail: Format.date(low.date),
                    tint: amount.isNegative ? .red : (isLow(amount) ? .orange : nil)
                )
            }
            if let nextPay {
                StatTile(title: "Next pay", value: Format.money(nextPay.received), detail: "\(nextPay.sourceName), \(Format.date(nextPay.payDate))")
            }
            if let estimate {
                let position = estimate.position
                StatTile(
                    title: "Tax \(estimate.year.label)",
                    value: position.isNegative ? "Owing ~\(Format.wholeDollars(-position))" : "Refund ~\(Format.wholeDollars(position))",
                    detail: estimate.isEstimate ? "Estimate (some rates assumed)" : "Estimate from planned pays",
                    tint: position.isNegative ? .orange : nil
                )
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .topTrailing) {
            if let warning = projection.warnings.first {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
        }
    }

    private var syncDetail: String {
        if case .failed = model.syncStatus { return "Last sync failed" }
        guard let last = model.bank?.lastSync else { return "" }
        let minutes = Int(Date().timeIntervalSince(last) / 60)
        return minutes < 1 ? "Synced just now" : (minutes < 60 ? "Synced \(minutes) min ago" : "Synced \(LocalDate(chartDate: last).dayMonth())")
    }

    private func isLow(_ amount: Money) -> Bool {
        guard let threshold = model.document.settings.lowBalanceThreshold else { return false }
        return amount < threshold
    }
}

private struct BalancePoint: Identifiable {
    let date: LocalDate
    let balance: Money
    var id: Int32 { date.dayNumber }
    var dollars: Double { Double(balance.cents) / 100 }
}

/// Running balance over the whole horizon. Click to move the grid to that date.
struct BalanceChart: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let points = model.projection.days.compactMap { day in
            day.closing.map { BalancePoint(date: day.date, balance: $0) }
        }
        if points.isEmpty {
            ContentUnavailableView(
                "No running total yet",
                systemImage: "chart.line.uptrend.xyaxis",
                description: Text("Click a cell in the Bank balance row to enter what's in your account.")
            )
        } else {
            chart(points)
        }
    }

    private func chart(_ points: [BalancePoint]) -> some View {
        let grid = model.grid
        let range = model.visibleRange(columns: model.visibleColumns)
        let windowStart = grid.buckets.isEmpty ? nil : grid.buckets[range.lowerBound].span.start
        let windowEnd = grid.buckets.isEmpty ? nil : grid.buckets[range.upperBound - 1].span.end.adding(days: 1)
        let lowest = model.projection.lowestUpcoming
        let hasNegative = points.contains { $0.balance.isNegative }

        return Chart {
            ForEach(grid.bands) { band in
                RectangleMark(
                    xStart: .value("Start", grid.buckets[band.firstBucket].span.start.chartDate),
                    xEnd: .value("End", grid.buckets[band.lastBucket].span.end.adding(days: 1).chartDate)
                )
                .foregroundStyle(band.color.color.opacity(0.14))
            }
            if let windowStart, let windowEnd {
                RectangleMark(
                    xStart: .value("Visible from", windowStart.chartDate),
                    xEnd: .value("Visible to", windowEnd.chartDate)
                )
                .foregroundStyle(Color.accentColor.opacity(0.07))
            }
            ForEach(points) { point in
                AreaMark(
                    x: .value("Date", point.date.chartDate),
                    y: .value("Balance", point.dollars)
                )
                .foregroundStyle(LinearGradient(
                    colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                ))
                LineMark(
                    x: .value("Date", point.date.chartDate),
                    y: .value("Balance", point.dollars)
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            RuleMark(x: .value("Today", model.projection.today.chartDate))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if hasNegative {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.red.opacity(0.5))
            }
            if let lowest, let amount = lowest.closing {
                PointMark(
                    x: .value("Lowest", lowest.date.chartDate),
                    y: .value("Balance", Double(amount.cents) / 100)
                )
                .foregroundStyle(amount.isNegative ? .red : .orange)
                .annotation(position: .bottom, spacing: 2) {
                    Text("Low \(Format.wholeDollars(amount))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let dollars = value.as(Double.self) {
                        Text(Format.compactDollars(dollars))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let origin = geometry[plotFrame].origin
                        if let date: Date = proxy.value(atX: location.x - origin.x) {
                            model.show(LocalDate(chartDate: date))
                        }
                    }
            }
        }
    }
}
