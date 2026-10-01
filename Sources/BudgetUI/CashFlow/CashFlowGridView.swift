import BudgetCore
import SwiftUI

enum GridMetrics {
    static let nameWidth: CGFloat = 230
    static let minCellWidth: CGFloat = 92
    static let rowHeight: CGFloat = 34
    static let scrollerAllowance: CGFloat = 16
}

/// The spreadsheet-like grid. Columns page with the toolbar, Go menu or arrow keys; the
/// item names, dates and totals stay put while rows scroll.
struct CashFlowGridView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var pager = HorizontalScrollPager()

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - GridMetrics.nameWidth - GridMetrics.scrollerAllowance)
            let columns = max(3, min(24, Int(available / GridMetrics.minCellWidth)))
            let cellWidth = floor(available / CGFloat(columns))
            let range = model.visibleRange(columns: columns)
            VStack(spacing: 0) {
                GridHeader(range: range, cellWidth: cellWidth)
                Divider()
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.grid.sections) { section in
                            let rows = section.hidesEmptyRows ? section.rows.filter { $0.hasValue(in: range) } : section.rows
                            if !rows.isEmpty {
                                SectionHeaderRow(section: section, rows: rows, range: range, cellWidth: cellWidth)
                                ForEach(rows) { row in
                                    GridRowView(row: row, range: range, cellWidth: cellWidth)
                                }
                            }
                        }
                        if model.grid.sections.isEmpty {
                            Text("Add bills, envelopes and income from the sidebar to fill in the grid.")
                                .foregroundStyle(.secondary)
                                .padding(24)
                        }
                    }
                }
                Divider()
                SummaryFooter(range: range, cellWidth: cellWidth)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) {
                model.move(by: -1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                model.move(by: 1)
                return .handled
            }
            .onAppear {
                model.visibleColumns = columns
                let model = model
                pager.start { step in
                    MainActor.assumeIsolated { model.move(by: step) }
                }
            }
            .onDisappear { pager.stop() }
            .onChange(of: columns) { _, newValue in model.visibleColumns = newValue }
        }
    }
}

/// Background for one column: today's column, period bands and past columns.
struct ColumnBackground: View {
    @Environment(AppModel.self) private var model
    let index: Int

    var body: some View {
        let grid = model.grid
        ZStack {
            if let band = grid.bands.first(where: { ($0.firstBucket...$0.lastBucket).contains(index) }) {
                band.color.color.opacity(0.09)
            }
            if grid.currentBucket == index {
                Color.accentColor.opacity(0.08)
            }
        }
    }
}

struct GridHeader: View {
    @Environment(AppModel.self) private var model
    let range: Range<Int>
    let cellWidth: CGFloat

    var body: some View {
        let grid = model.grid
        VStack(spacing: 0) {
            // Period bands (e.g. "Travel") above the dates.
            HStack(spacing: 0) {
                Color.clear.frame(width: GridMetrics.nameWidth, height: 16)
                ForEach(Array(range), id: \.self) { index in
                    let band = grid.bands.first { ($0.firstBucket...$0.lastBucket).contains(index) }
                    ZStack(alignment: .leading) {
                        if let band {
                            band.color.color.opacity(0.35)
                            if index == max(band.firstBucket, range.lowerBound) {
                                Text(band.name)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.leading, 4)
                            }
                        }
                    }
                    .frame(width: cellWidth, height: 16)
                }
            }
            HStack(spacing: 0) {
                Text(grid.granularity == .week ? "Week starting" : (grid.granularity == .day ? "Day" : "Month"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .frame(width: GridMetrics.nameWidth, alignment: .leading)
                ForEach(Array(range), id: \.self) { index in
                    let bucket = grid.buckets[index]
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(bucket.title)
                            .font(.caption.weight(bucket.containsToday ? .bold : .semibold))
                            .foregroundStyle(bucket.containsToday ? Color.accentColor : Color.primary)
                        Text(bucket.containsToday ? "Now" : bucket.subtitle)
                            .font(.caption2)
                            .foregroundStyle(bucket.containsToday ? Color.accentColor : Color.secondary)
                    }
                    .frame(width: cellWidth - 8, alignment: .trailing)
                    .padding(.trailing, 8)
                    .padding(.vertical, 5)
                    .background(ColumnBackground(index: index))
                }
            }
        }
        .background(.bar)
    }
}

struct SectionHeaderRow: View {
    let section: CashFlowSection
    let rows: [CashFlowRow]
    let range: Range<Int>
    let cellWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let color = section.color {
                    Circle().fill(color.color).frame(width: 8, height: 8)
                }
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.leading, 12)
            .frame(width: GridMetrics.nameWidth, alignment: .leading)
            ForEach(Array(range), id: \.self) { index in
                let total = rows.reduce(Money.zero) { $0 + ($1.cells[index].amount ?? .zero) }
                Text(total.isZero ? "" : Format.money(total))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: cellWidth - 8, alignment: .trailing)
                    .padding(.trailing, 8)
                    .frame(height: 26)
                    .background(ColumnBackground(index: index))
            }
        }
        .background(Color.secondary.opacity(0.06))
    }
}

struct GridRowView: View {
    let row: CashFlowRow
    let range: Range<Int>
    let cellWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.callout)
                        .lineLimit(1)
                    Text(row.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 20)
                .frame(width: GridMetrics.nameWidth, alignment: .leading)
                ForEach(Array(range), id: \.self) { index in
                    GridCellView(row: row, index: index)
                        .frame(width: cellWidth, height: GridMetrics.rowHeight)
                }
            }
            Divider().opacity(0.5)
        }
    }
}

struct GridCellView: View {
    @Environment(AppModel.self) private var model
    let row: CashFlowRow
    let index: Int
    @State private var editing = false

    var body: some View {
        let cell = row.cells[index]
        Button {
            if !cell.keys.isEmpty || (row.kind == .other && cell.status != .empty) { editing = true }
        } label: {
            CellContent(cell: cell, isInflow: row.isInflow)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(ColumnBackground(index: index))
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            CellEditor(row: row, bucketIndex: index)
        }
    }
}

struct CellContent: View {
    let cell: CashFlowCell
    let isInflow: Bool

    var body: some View {
        HStack(spacing: 3) {
            switch cell.status {
            case .empty:
                EmptyView()
            case .planned:
                amountText(color: isInflow ? .green : .primary)
            case .actual:
                amountText(color: .secondary)
            case .assumed:
                amountText(color: .secondary)
            case .matched:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                amountText(color: .primary)
            case .pending:
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                amountText(color: .primary)
            case .missed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                amountText(color: .red)
            case .paused:
                Text("paused").font(.caption2).foregroundStyle(.tertiary)
            case .skipped:
                Text("skipped").font(.caption2).foregroundStyle(.tertiary)
            case .unpaid:
                Text("unpaid").font(.caption2).foregroundStyle(.orange)
            }
        }
        .overlay(alignment: .topTrailing) {
            if cell.isOverridden {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                    .offset(x: 6, y: -4)
            }
        }
    }

    private func amountText(color: Color) -> some View {
        Text(cell.amount.map(Format.money) ?? "")
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(color)
    }
}

/// The rows under the grid: totals out and in, any balance you entered, and the running balance.
struct SummaryFooter: View {
    @Environment(AppModel.self) private var model
    let range: Range<Int>
    let cellWidth: CGFloat

    var body: some View {
        let summary = model.grid.summary
        VStack(spacing: 0) {
            footerRow("Total out", range: range) { index in
                Text(Format.money(summary.totalOut[index]))
                    .foregroundStyle(.secondary)
            }
            footerRow("Income", range: range) { index in
                Text(summary.totalIn[index].isZero ? "" : Format.money(summary.totalIn[index]))
                    .foregroundStyle(.green)
            }
            if model.projection.mode == .manual {
                footerRow("Bank balance", subtitle: "Click to enter a balance", range: range) { index in
                    CheckpointCell(index: index)
                }
            }
            footerRow(model.projection.mode == .bank ? "Balance" : "Running balance",
                      subtitle: model.projection.mode == .bank ? "Actual, then projected" : nil, bold: true, range: range) { index in
                let closing = summary.closing[index]
                Text(closing.map(Format.money) ?? "–")
                    .fontWeight(.semibold)
                    .foregroundStyle(color(for: closing))
            }
        }
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func color(for amount: Money?) -> Color {
        guard let amount else { return .secondary }
        if amount.isNegative { return .red }
        if let threshold = model.document.settings.lowBalanceThreshold, amount < threshold { return .orange }
        return .primary
    }

    private func footerRow<Content: View>(
        _ title: String, subtitle: String? = nil, bold: Bool = false, range: Range<Int>,
        @ViewBuilder content: @escaping (Int) -> Content
    ) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(bold ? .callout.weight(.semibold) : .callout)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 12)
            .frame(width: GridMetrics.nameWidth, alignment: .leading)
            ForEach(Array(range), id: \.self) { index in
                content(index)
                    .font(.callout)
                    .monospacedDigit()
                    .frame(width: cellWidth - 8, alignment: .trailing)
                    .padding(.trailing, 8)
                    .frame(height: 24)
                    .background(ColumnBackground(index: index))
            }
        }
    }
}

/// Shows a balance you entered in this column, and lets you add or change one.
struct CheckpointCell: View {
    @Environment(AppModel.self) private var model
    let index: Int
    @State private var editing = false

    var body: some View {
        let value = model.grid.summary.checkpoint[index]
        Button {
            editing = true
        } label: {
            Text(value.map(Format.money) ?? "+")
                .foregroundStyle(value == nil ? Color.secondary.opacity(0.5) : Color.blue)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $editing, arrowEdge: .top) {
            CheckpointEditor(bucket: model.grid.buckets[index])
        }
    }
}
