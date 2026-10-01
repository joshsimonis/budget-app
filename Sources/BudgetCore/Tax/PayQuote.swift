/// Inputs for the standalone pay calculator.
public struct PayQuoteInput: Hashable, Sendable {
    public var amount: Money
    public var unit: RateUnit
    public var superMode: SuperMode
    public var kind: EmploymentKind
    public var workDaysPerWeek: Int
    public var claimsTaxFreeThreshold: Bool
    public var salarySacrificePerYear: Money
    public var afterTaxSuperPerYear: Money
    public var gstRegistered: Bool
    public var applyStandardDeduction: Bool
    public var year: FinancialYear

    public init(
        amount: Money,
        unit: RateUnit,
        superMode: SuperMode = .onTop,
        kind: EmploymentKind = .salaried,
        workDaysPerWeek: Int = 5,
        claimsTaxFreeThreshold: Bool = true,
        salarySacrificePerYear: Money = .zero,
        afterTaxSuperPerYear: Money = .zero,
        gstRegistered: Bool = false,
        applyStandardDeduction: Bool = true,
        year: FinancialYear
    ) {
        self.amount = amount
        self.unit = unit
        self.superMode = superMode
        self.kind = kind
        self.workDaysPerWeek = workDaysPerWeek
        self.claimsTaxFreeThreshold = claimsTaxFreeThreshold
        self.salarySacrificePerYear = salarySacrificePerYear
        self.afterTaxSuperPerYear = afterTaxSuperPerYear
        self.gstRegistered = gstRegistered
        self.applyStandardDeduction = applyStandardDeduction
        self.year = year
    }
}

public struct PayQuoteRow: Hashable, Sendable, Identifiable {
    public var label: String
    public var periodsPerYear: Int
    public var breakdown: PayBreakdown
    public var id: String { label }
}

/// The pay calculator's answer: per-pay breakdowns plus the year's actual tax.
public struct PayQuote: Hashable, Sendable {
    public var input: PayQuoteInput
    public var data: TaxYearData
    /// The quoted rate turned into a yearly figure (a package if super is included).
    public var annualQuoted: Money
    /// Yearly pay excluding super (ABN: fees excluding GST).
    public var annualBase: Money
    public var annualSuperGuarantee: Money
    /// Weekly, fortnightly and monthly pays (what lands in your account), then the year.
    public var rows: [PayQuoteRow]
    /// Tax actually owed for the year (brackets − offset + Medicare).
    public var annualTax: TaxComputation
    public var standardDeduction: Money
    /// What weekly pays would have withheld over the year, to compare with `annualTax`.
    public var annualWithheldIfWeekly: Money
    public var concessionalContributions: Money
    public var exceedsConcessionalCap: Bool

    /// Positive: expected refund. Negative: expected bill. (Payroll only.)
    public var expectedRefund: Money { annualWithheldIfWeekly - annualTax.total }

    public static func make(_ input: PayQuoteInput) -> PayQuote {
        let data = TaxTables.data(for: input.year)
        let days = max(1, input.workDaysPerWeek)
        let rate = RateSegment(from: input.year.start, amount: input.amount, unit: input.unit, superMode: input.superMode)
        let annualQuoted = RateMath.annualize(input.amount, unit: input.unit, workDaysPerWeek: days)
        let annualBase = RateMath.annualBase(rate, kind: input.kind, workDaysPerWeek: days, data: data)
        let isABN = input.kind == .abn
        let sacrifice = min(max(input.salarySacrificePerYear, .zero), annualBase)
        let deduction = input.applyStandardDeduction ? data.standardDeduction : .zero
        let taxableIncome = max(annualBase - sacrifice - deduction, .zero)
        let annualTax = AnnualTax.compute(taxableIncome: taxableIncome, data: data)
        let superBaseAnnual = min(annualBase, data.maxContributionBase)
        let annualSG = isABN ? .zero : SuperCalc.guarantee(on: superBaseAnnual, data: data)

        func breakdown(periods: Int, frequency: PayFrequency) -> PayBreakdown {
            let n = Int64(periods)
            if isABN {
                let fee = annualBase.scaled(1, n)
                var result = PayCalculator.abn(fee: fee, gstRegistered: input.gstRegistered, contribution: sacrifice.scaled(1, n))
                if annualBase.isPositive {
                    result.taxSetAside = annualTax.total.scaled(fee.cents, annualBase.cents)
                }
                return result
            }
            return PayCalculator.payroll(
                kind: input.kind,
                gross: annualBase.scaled(1, n),
                frequency: frequency,
                claimsTaxFreeThreshold: input.claimsTaxFreeThreshold,
                salarySacrifice: sacrifice.scaled(1, n),
                afterTaxSuper: input.afterTaxSuperPerYear.scaled(1, n),
                superBase: superBaseAnnual.scaled(1, n),
                data: data
            )
        }

        var rows = [
            PayQuoteRow(label: "Weekly", periodsPerYear: 52, breakdown: breakdown(periods: 52, frequency: .weekly)),
            PayQuoteRow(label: "Fortnightly", periodsPerYear: 26, breakdown: breakdown(periods: 26, frequency: .fortnightly)),
            PayQuoteRow(label: "Monthly", periodsPerYear: 12, breakdown: breakdown(periods: 12, frequency: .monthly)),
        ]

        let afterTax = min(max(input.afterTaxSuperPerYear, .zero), max(annualBase - sacrifice - annualTax.total, .zero))
        var yearly: PayBreakdown
        if isABN {
            yearly = PayCalculator.abn(fee: annualBase, gstRegistered: input.gstRegistered, contribution: sacrifice)
            yearly.taxSetAside = annualTax.total
        } else {
            yearly = PayBreakdown(
                kind: input.kind,
                gross: annualBase,
                salarySacrifice: sacrifice,
                taxable: annualBase - sacrifice,
                withholding: annualTax.total,
                afterTaxSuper: afterTax,
                net: annualBase - sacrifice - annualTax.total - afterTax,
                superGuarantee: annualSG,
                usesEstimatedTables: data.isEstimate
            )
        }
        rows.append(PayQuoteRow(label: "Yearly", periodsPerYear: 1, breakdown: yearly))

        let withheldIfWeekly = isABN ? .zero : rows[0].breakdown.withholding * 52
        let concessional = annualSG + sacrifice
        return PayQuote(
            input: input,
            data: data,
            annualQuoted: annualQuoted,
            annualBase: annualBase,
            annualSuperGuarantee: annualSG,
            rows: rows,
            annualTax: annualTax,
            standardDeduction: deduction,
            annualWithheldIfWeekly: withheldIfWeekly,
            concessionalContributions: concessional,
            exceedsConcessionalCap: concessional > data.concessionalCap
        )
    }
}
