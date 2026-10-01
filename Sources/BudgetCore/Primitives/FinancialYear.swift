/// An Australian financial (income) year, 1 July – 30 June. `startYear` 2026 is "2026–27".
public struct FinancialYear: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let startYear: Int

    public init(startYear: Int) {
        self.startYear = startYear
    }

    public init(containing date: LocalDate) {
        let (y, m, _) = date.components
        startYear = m >= 7 ? y : y - 1
    }

    public var start: LocalDate { LocalDate(startYear, 7, 1) }
    public var end: LocalDate { LocalDate(startYear + 1, 6, 30) }
    public var span: DateSpan { DateSpan(start: start, end: end) }
    public var next: FinancialYear { FinancialYear(startYear: startYear + 1) }
    public var previous: FinancialYear { FinancialYear(startYear: startYear - 1) }

    /// "2026–27"
    public var label: String {
        let suffix = (startYear + 1) % 100
        return "\(startYear)–" + (suffix < 10 ? "0\(suffix)" : "\(suffix)")
    }

    public var description: String { label }

    public static func < (lhs: FinancialYear, rhs: FinancialYear) -> Bool { lhs.startYear < rhs.startYear }
}

extension LocalDate {
    public var financialYear: FinancialYear { FinancialYear(containing: self) }
}
