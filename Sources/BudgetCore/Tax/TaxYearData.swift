/// A resident tax bracket: tax = base + rate × (taxable income − threshold) above `threshold`.
public struct TaxBracket: Hashable, Sendable {
    /// Whole dollars.
    public var threshold: Int64
    /// Tax on income up to the threshold, in cents.
    public var baseTaxCents: Int64
    /// Marginal rate in basis points (1500 = 15%).
    public var rateBasisPoints: Int64

    public init(threshold: Int64, baseTaxCents: Int64, rateBasisPoints: Int64) {
        self.threshold = threshold
        self.baseTaxCents = baseTaxCents
        self.rateBasisPoints = rateBasisPoints
    }
}

/// One band of an ATO Schedule 1 formula, y = a·x − b, with a and b stored × 10⁴.
public struct WithholdingBand: Hashable, Sendable {
    /// x (weekly earnings in whole dollars, plus 99c) must be below this; nil = top band.
    public var below: Int64?
    public var a: Int64
    public var b: Int64

    public init(below: Int64?, a: Int64, b: Int64) {
        self.below = below
        self.a = a
        self.b = b
    }
}

/// Low income tax offset parameters (all whole dollars except the cents fields).
public struct LowIncomeTaxOffset: Hashable, Sendable {
    public var maximumCents: Int64
    public var firstTaperStart: Int64
    public var firstTaperBasisPoints: Int64
    public var secondTaperStart: Int64
    public var secondTaperBaseCents: Int64
    public var secondTaperBasisPoints: Int64

    /// The offset for a taxable income in whole dollars, in cents.
    public func amountCents(taxableDollars ti: Int64) -> Int64 {
        if ti <= firstTaperStart { return maximumCents }
        if ti <= secondTaperStart {
            return max(0, maximumCents - (ti - firstTaperStart) * firstTaperBasisPoints / 100)
        }
        return max(0, secondTaperBaseCents - IntMath.roundedDiv((ti - secondTaperStart) * secondTaperBasisPoints, 100))
    }
}

/// Everything needed to work out tax, super and withholding for one financial year.
public struct TaxYearData: Hashable, Sendable {
    public var year: FinancialYear
    public var brackets: [TaxBracket]
    public var medicareRateBasisPoints: Int64
    /// Singles: no levy at or below this taxable income (whole dollars).
    public var medicareLowIncomeThreshold: Int64
    /// The levy shades in at this rate above the threshold.
    public var medicareShadeInBasisPoints: Int64
    public var lowIncomeTaxOffset: LowIncomeTaxOffset
    public var superGuaranteeBasisPoints: Int64
    /// Maximum super contribution base for the year.
    public var maxContributionBase: Money
    public var concessionalCap: Money
    /// The standard deduction for work-related expenses (zero if not available that year).
    public var standardDeduction: Money
    /// Schedule 1 Scale 1 (no tax-free threshold).
    public var scale1: [WithholdingBand]
    /// Schedule 1 Scale 2 (tax-free threshold claimed).
    public var scale2: [WithholdingBand]
    /// True when some figures are borrowed from another year.
    public var isEstimate: Bool
    public var notes: [String]

    public var superGuaranteeRateLabel: String {
        let whole = superGuaranteeBasisPoints / 100
        let fraction = superGuaranteeBasisPoints % 100
        return fraction == 0 ? "\(whole)%" : "\(whole).\(fraction)%"
    }
}
