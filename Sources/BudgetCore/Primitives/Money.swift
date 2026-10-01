import Foundation

/// An amount of Australian dollars, stored as whole cents so sums are exact.
public struct Money: Hashable, Comparable, Sendable, AdditiveArithmetic, Codable, CustomStringConvertible {
    public var cents: Int64

    public init(cents: Int64) {
        self.cents = cents
    }

    public static func dollars(_ dollars: Int64) -> Money {
        Money(cents: dollars * 100)
    }

    public static let zero = Money(cents: 0)

    // MARK: Arithmetic

    public static func + (lhs: Money, rhs: Money) -> Money { Money(cents: lhs.cents + rhs.cents) }
    public static func - (lhs: Money, rhs: Money) -> Money { Money(cents: lhs.cents - rhs.cents) }
    public static func += (lhs: inout Money, rhs: Money) { lhs.cents += rhs.cents }
    public static func -= (lhs: inout Money, rhs: Money) { lhs.cents -= rhs.cents }
    public static prefix func - (value: Money) -> Money { Money(cents: -value.cents) }
    public static func * (lhs: Money, rhs: Int) -> Money { Money(cents: lhs.cents * Int64(rhs)) }
    public static func * (lhs: Int, rhs: Money) -> Money { rhs * lhs }
    public static func < (lhs: Money, rhs: Money) -> Bool { lhs.cents < rhs.cents }

    public var isZero: Bool { cents == 0 }
    public var isNegative: Bool { cents < 0 }
    public var isPositive: Bool { cents > 0 }
    public var magnitude: Money { Money(cents: cents < 0 ? -cents : cents) }

    /// self × num / den, rounded to the nearest cent (halves away from zero).
    public func scaled(_ num: Int64, _ den: Int64) -> Money {
        Money(cents: IntMath.roundedDiv(cents * num, den))
    }

    /// self × basisPoints / 10,000 (e.g. 1200 bp = 12%).
    public func percent(basisPoints: Int) -> Money {
        scaled(Int64(basisPoints), 10_000)
    }

    /// Splits into `parts` amounts that differ by at most one cent and add up exactly.
    /// Leftover cents go to the earliest parts.
    public func split(_ parts: Int) -> [Money] {
        precondition(parts > 0, "split needs at least one part")
        let n = Int64(parts)
        let sign: Int64 = cents < 0 ? -1 : 1
        let total = cents * sign
        let base = total / n
        let extra = Int(total % n)
        return (0..<parts).map { index in
            Money(cents: sign * (base + (index < extra ? 1 : 0)))
        }
    }

    /// Whole dollars, dropping any cents (toward zero).
    public var wholeDollars: Int64 { cents / 100 }

    // MARK: Codable (plain integer cents)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        cents = try container.decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(cents)
    }

    public var description: String { MoneyFormat.string(self) }
}

extension Money {
    /// Parses user input such as "1,234.56", "$12", "-3.5", "(40.00)" or "12.345" (rounded to cents).
    public init?(parsing text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast())
        }
        if s.hasPrefix("-") {
            negative.toggle()
            s.removeFirst()
        } else if s.hasPrefix("+") {
            s.removeFirst()
        }
        s = s.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        if s.hasPrefix("-") {
            negative.toggle()
            s.removeFirst()
        }
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let wholeText = parts[0].isEmpty ? "0" : String(parts[0])
        guard wholeText.allSatisfy(\.isASCIIDigit), let whole = Int64(wholeText) else { return nil }
        var cents = whole * 100
        if parts.count == 2 {
            let fraction = String(parts[1])
            guard fraction.allSatisfy(\.isASCIIDigit) else { return nil }
            if !fraction.isEmpty {
                // Use up to 3 digits so we can round half up to cents.
                let padded = (fraction + "000").prefix(3)
                guard let thousandths = Int64(padded) else { return nil }
                cents += (thousandths + 5) / 10
            }
        }
        self.cents = negative ? -cents : cents
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// Locale-independent money formatting ("$1,234.56", "-$12.00").
public enum MoneyFormat {
    public static func string(_ money: Money, showCents: Bool = true, showPlus: Bool = false, symbol: Bool = true) -> String {
        let negative = money.cents < 0
        let absolute = negative ? -money.cents : money.cents
        var dollars = absolute / 100
        let cents = absolute % 100
        if !showCents && cents >= 50 {
            dollars += 1
        }
        let grouped = groupThousands(dollars)
        var result = symbol ? "$" + grouped : grouped
        if showCents {
            result += "." + (cents < 10 ? "0\(cents)" : "\(cents)")
        }
        if negative && (showCents ? absolute != 0 : (dollars != 0)) {
            result = "-" + result
        } else if showPlus && money.cents > 0 {
            result = "+" + result
        }
        return result
    }

    /// Plain number for editing fields: "1234.56" (no grouping, no symbol).
    public static func plain(_ money: Money) -> String {
        let negative = money.cents < 0
        let absolute = negative ? -money.cents : money.cents
        let cents = absolute % 100
        let text = "\(absolute / 100)." + (cents < 10 ? "0\(cents)" : "\(cents)")
        return negative ? "-" + text : text
    }

    static func groupThousands(_ value: Int64) -> String {
        let digits = String(value)
        var out = ""
        for (index, char) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 {
                out.append(",")
            }
            out.append(char)
        }
        return out
    }
}
