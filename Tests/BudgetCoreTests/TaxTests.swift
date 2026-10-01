import Testing
@testable import BudgetCore

private let fy26 = TaxTables.fy2026
private func dollars(_ d: Int64) -> Money { .dollars(d) }
private func cents(_ c: Int64) -> Money { Money(cents: c) }

@Suite struct Schedule1Tests {
    @Test func atoWorkedExample() {
        // ATO: $563 a week, tax-free threshold claimed → $33.
        #expect(Schedule1.withholding(earnings: dollars(563), frequency: .weekly, claimsTaxFreeThreshold: true, data: fy26) == dollars(33))
        #expect(Schedule1.withholding(earnings: dollars(563), frequency: .weekly, claimsTaxFreeThreshold: false, data: fy26) == dollars(108))
    }

    @Test(arguments: [
        (361, 0), (362, 0), (370, 1), (2800, 729), (3500, 1002), (5000, 1695),
    ] as [(Int64, Int64)])
    func weeklyScale2(earnings: Int64, withheld: Int64) {
        #expect(Schedule1.withholding(earnings: dollars(earnings), frequency: .weekly, claimsTaxFreeThreshold: true, data: fy26) == dollars(withheld))
    }

    @Test func otherPayPeriods() {
        #expect(Schedule1.withholding(earnings: dollars(1126), frequency: .fortnightly, claimsTaxFreeThreshold: true, data: fy26) == dollars(66))
        // Monthly with the ".33 cents" rule: 2,439.33 → 2,439.34 × 3/13 = 562.92 → $562 → $33 → × 13/3 = $143.
        #expect(Schedule1.withholding(earnings: cents(243_933), frequency: .monthly, claimsTaxFreeThreshold: true, data: fy26) == dollars(143))
        #expect(Schedule1.withholding(earnings: dollars(7319), frequency: .quarterly, claimsTaxFreeThreshold: true, data: fy26) == dollars(429))
        #expect(Schedule1.withholding(earnings: dollars(2252), frequency: .fourWeekly, claimsTaxFreeThreshold: true, data: fy26) == dollars(132))
        // A 10-day period falls back to a weekly equivalent.
        #expect(Schedule1.withholding(earnings: dollars(5000), periodDays: 7, claimsTaxFreeThreshold: true, data: fy26) == dollars(1695))
    }

    @Test func halfDollarRoundsUp() {
        // y = 0.5·x − 0.495 at x = 1.99 → exactly $0.50 → $1.
        let bands = [WithholdingBand(below: nil, a: 5000, b: 4950)]
        #expect(Schedule1.weeklyDollars(earningsCents: 100, bands: bands) == 1)
        let justUnder = [WithholdingBand(below: nil, a: 5000, b: 4951)]
        #expect(Schedule1.weeklyDollars(earningsCents: 100, bands: justUnder) == 0)
    }

    @Test(arguments: [true, false])
    func scalesAreMonotonicAndContinuous(claimsThreshold: Bool) {
        let bands = claimsThreshold ? fy26.scale2 : fy26.scale1
        var previous: Int64 = 0
        for dollarsEarned in Int64(0)...6000 {
            let y = Schedule1.weeklyDollars(earningsCents: dollarsEarned * 100, bands: bands)
            #expect(y >= previous, "withholding fell at $\(dollarsEarned)")
            #expect(y - previous <= 1, "withholding jumped by more than $1 at $\(dollarsEarned)")
            previous = y
        }
    }
}

@Suite struct SuperAndRateTests {
    @Test func packagesIncludingSuper() {
        #expect(SuperCalc.baseFromPackage(dollars(112_000), data: fy26) == dollars(100_000))
        // Above the maximum contribution base ($270,830 × 1.12) the SG is capped at $32,499.60.
        #expect(SuperCalc.baseFromPackage(dollars(400_000), data: fy26) == cents(36_750_040))
        #expect(SuperCalc.guarantee(on: dollars(3500), data: fy26) == dollars(420))
    }

    @Test func rateConversions() {
        let daily = RateSegment(from: LocalDate(2026, 7, 1), amount: dollars(750), unit: .daily, superMode: .included)
        #expect(RateMath.dailyBase(daily, kind: .dayRate, workDaysPerWeek: 5, data: fy26) == cents(66_964))
        #expect(RateMath.dailyBase(daily, kind: .abn, workDaysPerWeek: 5, data: fy26) == dollars(750))
        #expect(RateMath.annualize(dollars(750), unit: .daily, workDaysPerWeek: 5) == dollars(195_000))
        #expect(RateMath.annualize(dollars(2000), unit: .fortnightly, workDaysPerWeek: 5) == dollars(52_000))
        let salary = RateSegment(from: LocalDate(2026, 7, 1), amount: dollars(100_000), unit: .annual, superMode: .included)
        #expect(RateMath.annualBase(salary, kind: .salaried, workDaysPerWeek: 5, data: fy26) == cents(8_928_571))
        let annualOnTop = RateSegment(from: LocalDate(2026, 7, 1), amount: dollars(130_000), unit: .annual)
        #expect(RateMath.dailyBase(annualOnTop, kind: .salaried, workDaysPerWeek: 5, data: fy26) == dollars(500))
    }
}

@Suite struct AnnualTaxTests {
    @Test(arguments: [
        // taxable, income tax, offset used, Medicare, total (all cents)
        (18_200, 0, 0, 0, 0),
        (20_000, 27_000, 27_000, 0, 0),
        (30_000, 177_000, 70_000, 19_890, 126_890),
        (40_000, 327_000, 57_500, 80_000, 349_500),
        (45_000, 402_000, 32_500, 90_000, 459_500),
        (50_000, 552_000, 25_000, 100_000, 627_000),
        (100_000, 2_052_000, 0, 200_000, 2_252_000),
        (200_000, 5_587_000, 0, 400_000, 5_987_000),
    ] as [(Int64, Int64, Int64, Int64, Int64)])
    func residentTax2026(taxable: Int64, incomeTax: Int64, offset: Int64, medicare: Int64, total: Int64) {
        let result = AnnualTax.compute(taxableIncome: dollars(taxable), data: fy26)
        #expect(result.incomeTax == cents(incomeTax))
        #expect(result.lowIncomeTaxOffset == cents(offset))
        #expect(result.medicareLevy == cents(medicare))
        #expect(result.total == cents(total))
    }

    @Test func year2027UsesFourteenPercent() {
        let result = AnnualTax.compute(taxableIncome: dollars(100_000), data: TaxTables.fy2027)
        #expect(result.total == dollars(22_252))
        #expect(TaxTables.fy2027.isEstimate)
    }

    @Test func bracketEdgesAreContinuous() {
        for data in [TaxTables.fy2026, TaxTables.fy2027] {
            for bracket in data.brackets.dropFirst() {
                let below = AnnualTax.compute(taxableIncome: dollars(bracket.threshold), data: data).incomeTax
                #expect(below == cents(bracket.baseTaxCents), "\(data.year.label) base at \(bracket.threshold)")
            }
        }
    }

    @Test func unknownYearsBorrowNearestData() {
        #expect(TaxTables.data(for: FinancialYear(startYear: 2030)).isEstimate)
        #expect(TaxTables.data(for: FinancialYear(startYear: 2030)).brackets[1].rateBasisPoints == 1400)
        #expect(TaxTables.data(for: FinancialYear(startYear: 2025)).isEstimate)
        #expect(!TaxTables.data(for: LocalDate(2026, 10, 1)).isEstimate)
    }

    @Test func marginalRate() {
        #expect(AnnualTax.marginalRateBasisPoints(taxableIncome: dollars(150_000), data: fy26) == 3900)
        #expect(AnnualTax.marginalRateBasisPoints(taxableIncome: dollars(20_000), data: fy26) == 1500)
    }
}

@Suite struct PayCalculatorTests {
    @Test func payrollPay() {
        let pay = PayCalculator.payroll(gross: dollars(3500), frequency: .weekly, claimsTaxFreeThreshold: true, data: fy26)
        #expect(pay.withholding == dollars(1002))
        #expect(pay.net == dollars(2498))
        #expect(pay.superGuarantee == dollars(420))
    }

    @Test func salarySacrificeReducesTaxNotSuperBase() {
        let pay = PayCalculator.payroll(gross: dollars(3500), frequency: .weekly, claimsTaxFreeThreshold: true,
                                        salarySacrifice: dollars(500), data: fy26)
        #expect(pay.taxable == dollars(3000))
        #expect(pay.withholding == dollars(807))
        #expect(pay.net == dollars(2193))
        #expect(pay.superGuarantee == dollars(420))
        #expect(pay.totalSuper == dollars(920))
    }

    @Test func afterTaxSuperComesOutOfNet() {
        let pay = PayCalculator.payroll(gross: dollars(3500), frequency: .weekly, claimsTaxFreeThreshold: true,
                                        afterTaxSuper: dollars(100), data: fy26)
        #expect(pay.net == dollars(2398))
    }

    @Test func abnInvoice() {
        let registered = PayCalculator.abn(fee: dollars(5000), gstRegistered: true)
        #expect(registered.gst == dollars(500))
        #expect(registered.net == dollars(5500))
        #expect(registered.gstSetAside == dollars(500))
        #expect(registered.withholding == .zero)
        let unregistered = PayCalculator.abn(fee: dollars(5000), gstRegistered: false, contribution: dollars(200))
        #expect(unregistered.net == dollars(4800))
        #expect(unregistered.taxable == dollars(4800))
    }

    @Test func quoteForSalary() {
        let quote = PayQuote.make(PayQuoteInput(amount: dollars(100_000), unit: .annual, applyStandardDeduction: false,
                                                year: FinancialYear(startYear: 2026)))
        let weekly = quote.rows[0].breakdown
        #expect(weekly.gross == cents(192_308))
        #expect(weekly.withholding == dollars(434))
        #expect(quote.rows[1].breakdown.withholding == dollars(868))
        #expect(quote.rows[2].breakdown.gross == cents(833_333))
        #expect(quote.rows[2].breakdown.withholding == dollars(1881))
        #expect(quote.annualTax.total == dollars(22_520))
        #expect(quote.annualWithheldIfWeekly == dollars(22_568))
        #expect(quote.expectedRefund == dollars(48))
        #expect(quote.annualSuperGuarantee == dollars(12_000))
        #expect(!quote.exceedsConcessionalCap)
        #expect(quote.rows[3].breakdown.net == dollars(77_480))
    }

    @Test func quoteForPackageWithSacrificeOverCap() {
        let quote = PayQuote.make(PayQuoteInput(amount: dollars(224_000), unit: .annual, superMode: .included,
                                                salarySacrificePerYear: dollars(10_000), year: FinancialYear(startYear: 2026)))
        #expect(quote.annualBase == dollars(200_000))
        #expect(quote.annualSuperGuarantee == dollars(24_000))
        #expect(quote.exceedsConcessionalCap) // 24,000 + 10,000 > 32,500
    }

    @Test func quoteForABN() {
        let quote = PayQuote.make(PayQuoteInput(amount: dollars(1000), unit: .daily, kind: .abn, gstRegistered: true,
                                                year: FinancialYear(startYear: 2026)))
        #expect(quote.annualBase == dollars(260_000))
        #expect(quote.annualTax.total == dollars(87_600))
        let weekly = quote.rows[0].breakdown
        #expect(weekly.net == dollars(5500))
        #expect(weekly.taxSetAside == cents(168_462))
        #expect(weekly.spendable == cents(331_538))
        #expect(quote.annualSuperGuarantee == .zero)
    }
}
