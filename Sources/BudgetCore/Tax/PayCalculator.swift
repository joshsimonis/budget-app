/// What one pay works out to.
public struct PayBreakdown: Hashable, Sendable {
    public var kind: EmploymentKind
    /// Ordinary earnings for the pay. For ABN: the fee excluding GST.
    public var gross: Money
    /// Pre-tax super (for ABN: personal deductible contribution).
    public var salarySacrifice: Money
    /// Gross minus salary sacrifice.
    public var taxable: Money
    /// PAYG withheld (zero for ABN).
    public var withholding: Money
    public var afterTaxSuper: Money
    /// GST charged on an ABN invoice.
    public var gst: Money
    /// Cash received.
    public var net: Money
    /// Employer super guarantee (zero for ABN).
    public var superGuarantee: Money
    /// ABN: income tax to put aside from this payment.
    public var taxSetAside: Money
    /// ABN: GST to put aside for the BAS.
    public var gstSetAside: Money
    /// Withholding used tax tables borrowed from another year.
    public var usesEstimatedTables: Bool

    public init(
        kind: EmploymentKind, gross: Money = .zero, salarySacrifice: Money = .zero, taxable: Money = .zero,
        withholding: Money = .zero, afterTaxSuper: Money = .zero, gst: Money = .zero, net: Money = .zero,
        superGuarantee: Money = .zero, taxSetAside: Money = .zero, gstSetAside: Money = .zero,
        usesEstimatedTables: Bool = false
    ) {
        self.kind = kind
        self.gross = gross
        self.salarySacrifice = salarySacrifice
        self.taxable = taxable
        self.withholding = withholding
        self.afterTaxSuper = afterTaxSuper
        self.gst = gst
        self.net = net
        self.superGuarantee = superGuarantee
        self.taxSetAside = taxSetAside
        self.gstSetAside = gstSetAside
        self.usesEstimatedTables = usesEstimatedTables
    }

    /// Net pay minus anything that should be put aside.
    public var spendable: Money { net - taxSetAside - gstSetAside }

    /// Total super going in (employer SG + salary sacrifice + after-tax).
    public var totalSuper: Money { superGuarantee + salarySacrifice + afterTaxSuper }
}

public enum PayCalculator {
    /// A payroll pay (salaried or day rate): withholding on earnings after salary sacrifice.
    /// `superBase` is the ordinary earnings the employer pays super on (after any cap).
    public static func payroll(
        kind: EmploymentKind = .salaried,
        gross: Money,
        frequency: PayFrequency?,
        periodDays: Int = 7,
        claimsTaxFreeThreshold: Bool,
        salarySacrifice: Money = .zero,
        afterTaxSuper: Money = .zero,
        superBase: Money? = nil,
        data: TaxYearData
    ) -> PayBreakdown {
        let gross = max(gross, .zero)
        let sacrifice = min(max(salarySacrifice, .zero), gross)
        let taxable = gross - sacrifice
        let withholding: Money
        if let frequency {
            withholding = Schedule1.withholding(earnings: taxable, frequency: frequency, claimsTaxFreeThreshold: claimsTaxFreeThreshold, data: data)
        } else {
            withholding = Schedule1.withholding(earnings: taxable, periodDays: periodDays, claimsTaxFreeThreshold: claimsTaxFreeThreshold, data: data)
        }
        let afterTax = min(max(afterTaxSuper, .zero), max(taxable - withholding, .zero))
        return PayBreakdown(
            kind: kind,
            gross: gross,
            salarySacrifice: sacrifice,
            taxable: taxable,
            withholding: withholding,
            afterTaxSuper: afterTax,
            net: taxable - withholding - afterTax,
            superGuarantee: SuperCalc.guarantee(on: superBase ?? gross, data: data),
            usesEstimatedTables: data.isEstimate
        )
    }

    /// An ABN payment: no withholding; GST is collected on top if registered.
    public static func abn(fee: Money, gstRegistered: Bool, contribution: Money = .zero) -> PayBreakdown {
        let fee = max(fee, .zero)
        let gst = gstRegistered ? fee.percent(basisPoints: 1000) : .zero
        let contribution = min(max(contribution, .zero), fee)
        return PayBreakdown(
            kind: .abn,
            gross: fee,
            salarySacrifice: contribution,
            taxable: fee - contribution,
            gst: gst,
            net: fee + gst - contribution,
            gstSetAside: gst
        )
    }
}

/// Income tax for a year: brackets, low income tax offset and Medicare levy.
public struct TaxComputation: Hashable, Sendable {
    public var taxableIncome: Money
    public var incomeTax: Money
    /// The part of the low income tax offset that was used (it can't make tax negative).
    public var lowIncomeTaxOffset: Money
    public var medicareLevy: Money

    public var total: Money { incomeTax - lowIncomeTaxOffset + medicareLevy }
}

public enum AnnualTax {
    public static func compute(taxableIncome: Money, data: TaxYearData) -> TaxComputation {
        let dollars = max(0, taxableIncome.cents / 100)
        var incomeTaxCents: Int64 = 0
        if let bracket = data.brackets.last(where: { dollars > $0.threshold }) {
            incomeTaxCents = bracket.baseTaxCents + (dollars - bracket.threshold) * bracket.rateBasisPoints / 100
        }
        let lito = min(data.lowIncomeTaxOffset.amountCents(taxableDollars: dollars), incomeTaxCents)
        var medicareCents: Int64 = 0
        if dollars > data.medicareLowIncomeThreshold {
            let full = dollars * data.medicareRateBasisPoints / 100
            let shaded = (dollars - data.medicareLowIncomeThreshold) * data.medicareShadeInBasisPoints / 100
            medicareCents = min(full, shaded)
        }
        return TaxComputation(
            taxableIncome: .dollars(dollars),
            incomeTax: Money(cents: incomeTaxCents),
            lowIncomeTaxOffset: Money(cents: lito),
            medicareLevy: Money(cents: medicareCents)
        )
    }

    /// The marginal rate (income tax + Medicare) at a taxable income, in basis points.
    public static func marginalRateBasisPoints(taxableIncome: Money, data: TaxYearData) -> Int64 {
        let dollars = max(0, taxableIncome.cents / 100)
        let bracket = data.brackets.last { dollars > $0.threshold }?.rateBasisPoints ?? 0
        let medicare = dollars > data.medicareLowIncomeThreshold ? data.medicareRateBasisPoints : 0
        return bracket + medicare
    }
}
