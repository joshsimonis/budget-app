/// How often a pay is made, for PAYG withholding.
public enum PayFrequency: String, Codable, Sendable, CaseIterable {
    case weekly, fortnightly, fourWeekly, monthly, quarterly

    public var periodsPerYear: Int {
        switch self {
        case .weekly: 52
        case .fortnightly: 26
        case .fourWeekly: 13
        case .monthly: 12
        case .quarterly: 4
        }
    }

    public var label: String {
        switch self {
        case .weekly: "Weekly"
        case .fortnightly: "Fortnightly"
        case .fourWeekly: "Four-weekly"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        }
    }

    /// The frequency for a pay schedule, or nil if PAYG has no formula for it.
    public static func from(_ rule: RecurrenceRule) -> PayFrequency? {
        switch (rule.unit, rule.interval) {
        case (.week, 1): .weekly
        case (.week, 2): .fortnightly
        case (.week, 4): .fourWeekly
        case (.month, 1): .monthly
        case (.month, 3): .quarterly
        default: nil
        }
    }
}

/// ATO PAYG withholding, Schedule 1 (Statement of formulas), in integer arithmetic.
public enum Schedule1 {
    /// Withholding in whole dollars for weekly earnings (in cents):
    /// x = earnings with cents dropped + 99c; y = a·x − b rounded to the nearest dollar.
    public static func weeklyDollars(earningsCents: Int64, bands: [WithholdingBand]) -> Int64 {
        guard earningsCents > 0, !bands.isEmpty else { return 0 }
        let xCents = (earningsCents / 100) * 100 + 99
        let band = bands.first { band in band.below.map { xCents < $0 * 100 } ?? true } ?? bands[bands.count - 1]
        // a and b are × 10⁴, x is in cents → y in millionths of a dollar.
        let micro = band.a * xCents - band.b * 100
        guard micro > 0 else { return 0 }
        return (micro + 500_000) / 1_000_000
    }

    /// PAYG withholding for one pay.
    public static func withholding(earnings: Money, frequency: PayFrequency, claimsTaxFreeThreshold: Bool, data: TaxYearData) -> Money {
        let bands = claimsTaxFreeThreshold ? data.scale2 : data.scale1
        let cents = earnings.cents
        guard cents > 0 else { return .zero }
        let dollars: Int64
        switch frequency {
        case .weekly:
            dollars = weeklyDollars(earningsCents: cents, bands: bands)
        case .fortnightly:
            dollars = 2 * weeklyDollars(earningsCents: cents / 2, bands: bands)
        case .fourWeekly:
            dollars = 4 * weeklyDollars(earningsCents: cents / 4, bands: bands)
        case .monthly:
            let adjusted = cents % 100 == 33 ? cents + 1 : cents
            let weeklyWholeDollars = (adjusted * 3) / 1300
            let weekly = weeklyDollars(earningsCents: weeklyWholeDollars * 100, bands: bands)
            dollars = IntMath.roundedDiv(weekly * 13, 3)
        case .quarterly:
            dollars = 13 * weeklyDollars(earningsCents: cents / 13, bands: bands)
        }
        return .dollars(dollars)
    }

    /// For pay periods with no ATO formula: convert to a weekly equivalent and back.
    public static func withholding(earnings: Money, periodDays: Int, claimsTaxFreeThreshold: Bool, data: TaxYearData) -> Money {
        guard periodDays > 0, earnings.cents > 0 else { return .zero }
        let bands = claimsTaxFreeThreshold ? data.scale2 : data.scale1
        let weeklyCents = IntMath.roundedDiv(earnings.cents * 7, Int64(periodDays))
        let weekly = weeklyDollars(earningsCents: weeklyCents, bands: bands)
        return .dollars(IntMath.roundedDiv(weekly * Int64(periodDays), 7))
    }
}

/// Super guarantee helpers.
public enum SuperCalc {
    /// Annual base salary inside a package that includes super. Above the maximum
    /// contribution base the employer only owes super on the base, so the rest is salary.
    public static func baseFromPackage(_ package: Money, data: TaxYearData) -> Money {
        let rate = data.superGuaranteeBasisPoints
        let threshold = data.maxContributionBase.scaled(10_000 + rate, 10_000)
        if package <= threshold {
            return package.scaled(10_000, 10_000 + rate)
        }
        return package - data.maxContributionBase.percent(basisPoints: Int(rate))
    }

    public static func guarantee(on ordinaryEarnings: Money, data: TaxYearData) -> Money {
        ordinaryEarnings.percent(basisPoints: Int(data.superGuaranteeBasisPoints))
    }
}

/// Converting quoted pay rates.
public enum RateMath {
    public static func annualize(_ amount: Money, unit: RateUnit, workDaysPerWeek: Int) -> Money {
        switch unit {
        case .annual: amount
        case .monthly: amount * 12
        case .fortnightly: amount * 26
        case .weekly: amount * 52
        case .daily: amount * (max(1, workDaysPerWeek) * 52)
        }
    }

    /// Annual base pay excluding super (ABN fees are taken as quoted).
    public static func annualBase(_ rate: RateSegment, kind: EmploymentKind, workDaysPerWeek: Int, data: TaxYearData) -> Money {
        let annual = annualize(rate.amount, unit: rate.unit, workDaysPerWeek: workDaysPerWeek)
        guard kind != .abn, rate.superMode == .included else { return annual }
        return SuperCalc.baseFromPackage(annual, data: data)
    }

    /// Base pay for one day worked, excluding super.
    public static func dailyBase(_ rate: RateSegment, kind: EmploymentKind, workDaysPerWeek: Int, data: TaxYearData) -> Money {
        if rate.unit == .daily {
            guard kind != .abn, rate.superMode == .included else { return rate.amount }
            return rate.amount.scaled(10_000, 10_000 + data.superGuaranteeBasisPoints)
        }
        let annual = annualBase(rate, kind: kind, workDaysPerWeek: workDaysPerWeek, data: data)
        return annual.scaled(1, Int64(max(1, workDaysPerWeek) * 52))
    }
}
