import BudgetCore
import Foundation
import SwiftUI

enum Format {
    static func money(_ value: Money) -> String { MoneyFormat.string(value) }
    static func wholeDollars(_ value: Money) -> String { MoneyFormat.string(value, showCents: false) }
    static func signed(_ value: Money) -> String { MoneyFormat.string(value, showPlus: true) }

    /// "Thu 1 Oct 2026"
    static func date(_ date: LocalDate) -> String {
        "\(date.weekday.shortName) \(date.dayMonth(includeYear: true))"
    }

    /// "1–7 Oct" or "28 Sep – 4 Oct"
    static func span(_ span: DateSpan) -> String {
        if span.start == span.end { return span.start.dayMonth() }
        if span.start.month == span.end.month && span.start.year == span.end.year {
            return "\(span.start.day)–\(span.end.dayMonth())"
        }
        return "\(span.start.dayMonth()) – \(span.end.dayMonth())"
    }

    /// 450 → "4.5", 400 → "4"
    static func days(_ hundredths: Int) -> String {
        if hundredths % 100 == 0 { return "\(hundredths / 100)" }
        if hundredths % 10 == 0 { return "\(hundredths / 100).\((hundredths % 100) / 10)" }
        let fraction = hundredths % 100
        return "\(hundredths / 100)." + (fraction < 10 ? "0\(fraction)" : "\(fraction)")
    }

    /// Parses "4.5" into hundredths of a day.
    static func parseDays(_ text: String) -> Int? {
        guard let value = Money(parsing: text) else { return nil }
        return Int(value.cents)
    }

    /// Axis labels: "$12k", "-$3.5k", "$800".
    static func compactDollars(_ value: Double) -> String {
        let magnitude = abs(value)
        let sign = value < 0 ? "-" : ""
        if magnitude >= 1_000_000 { return "\(sign)$\(trim(magnitude / 1_000_000))m" }
        if magnitude >= 1000 { return "\(sign)$\(trim(magnitude / 1000))k" }
        return "\(sign)$\(Int(magnitude.rounded()))"
    }

    private static func trim(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))" : "\(rounded)"
    }
}

extension LocalDate {
    /// Noon UTC on this day: the same calendar date in every Australian time zone. For Charts.
    var chartDate: Date { Date(timeIntervalSince1970: Double(dayNumber) * 86_400 + 43_200) }

    init(chartDate: Date) {
        self.init(dayNumber: Int32((chartDate.timeIntervalSince1970 / 86_400).rounded(.down)))
    }

    /// Midday on this date in the Mac's calendar, for DatePicker.
    var pickerDate: Date {
        let (y, m, d) = components
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? chartDate
    }

    init(pickerDate: Date) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: pickerDate)
        self.init(c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }
}

extension Binding where Value == LocalDate {
    /// Adapts a LocalDate binding for DatePicker.
    var pickerDate: Binding<Date> {
        Binding<Date>(
            get: { wrappedValue.pickerDate },
            set: { wrappedValue = LocalDate(pickerDate: $0) }
        )
    }
}

extension PeriodColor {
    var color: Color {
        switch self {
        case .green: .green
        case .blue: .blue
        case .orange: .orange
        case .purple: .purple
        case .pink: .pink
        case .teal: .teal
        case .yellow: .yellow
        case .gray: .gray
        }
    }

    var label: String { rawValue.capitalized }
}

/// A small labelled figure, used in the summary strip.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String = ""
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? Color.primary)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 150, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

/// A text field for money that commits a parsed value.
struct MoneyField: View {
    let title: String
    @Binding var value: Money
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .onAppear { text = MoneyFormat.plain(value) }
            .onChange(of: value) { _, newValue in
                if !focused { text = MoneyFormat.plain(newValue) }
            }
            .onChange(of: text) { _, newText in
                if let parsed = Money(parsing: newText) { value = parsed }
            }
            .onSubmit { text = MoneyFormat.plain(value) }
    }
}
