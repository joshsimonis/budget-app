/// Built-in tax data. Sources: ATO "Tax rates – Australian residents", "Schedule 1 –
/// Statement of formulas for calculating amounts to be withheld" (from 1 July 2026),
/// "Low income tax offset", "Medicare levy reduction for low-income earners", and
/// "Key superannuation rates and thresholds". Check against ato.gov.au each July.
public enum TaxTables {
    private static let lito = LowIncomeTaxOffset(
        maximumCents: 70_000,
        firstTaperStart: 37_500, firstTaperBasisPoints: 500,
        secondTaperStart: 45_000, secondTaperBaseCents: 32_500, secondTaperBasisPoints: 150
    )

    /// Schedule 1 Scale 2 (tax-free threshold claimed), payments from 1 July 2026.
    private static let scale2From2026: [WithholdingBand] = [
        WithholdingBand(below: 362, a: 0, b: 0),
        WithholdingBand(below: 538, a: 1500, b: 543_462),
        WithholdingBand(below: 673, a: 2500, b: 1_082_135),
        WithholdingBand(below: 721, a: 1700, b: 543_473),
        WithholdingBand(below: 865, a: 1790, b: 608_377),
        WithholdingBand(below: 1282, a: 3227, b: 1_851_935),
        WithholdingBand(below: 2596, a: 3200, b: 1_817_319),
        WithholdingBand(below: 3653, a: 3900, b: 3_634_627),
        WithholdingBand(below: nil, a: 4700, b: 6_557_704),
    ]

    /// Schedule 1 Scale 1 (no tax-free threshold), payments from 1 July 2026.
    private static let scale1From2026: [WithholdingBand] = [
        WithholdingBand(below: 188, a: 1500, b: 1500),
        WithholdingBand(below: 371, a: 2084, b: 110_185),
        WithholdingBand(below: 515, a: 1790, b: 1066),
        WithholdingBand(below: 932, a: 3227, b: 741_674),
        WithholdingBand(below: 2246, a: 3200, b: 716_508),
        WithholdingBand(below: 3303, a: 3900, b: 2_288_816),
        WithholdingBand(below: nil, a: 4700, b: 4_931_893),
    ]

    public static let fy2026 = TaxYearData(
        year: FinancialYear(startYear: 2026),
        brackets: [
            TaxBracket(threshold: 0, baseTaxCents: 0, rateBasisPoints: 0),
            TaxBracket(threshold: 18_200, baseTaxCents: 0, rateBasisPoints: 1500),
            TaxBracket(threshold: 45_000, baseTaxCents: 402_000, rateBasisPoints: 3000),
            TaxBracket(threshold: 135_000, baseTaxCents: 3_102_000, rateBasisPoints: 3700),
            TaxBracket(threshold: 190_000, baseTaxCents: 5_137_000, rateBasisPoints: 4500),
        ],
        medicareRateBasisPoints: 200,
        medicareLowIncomeThreshold: 28_011,
        medicareShadeInBasisPoints: 1000,
        lowIncomeTaxOffset: lito,
        superGuaranteeBasisPoints: 1200,
        maxContributionBase: .dollars(270_830),
        concessionalCap: .dollars(32_500),
        standardDeduction: .dollars(1000),
        scale1: scale1From2026,
        scale2: scale2From2026,
        isEstimate: false,
        notes: ["The Medicare levy low-income threshold is the 2025–26 figure ($28,011); 2026–27 isn't published yet."]
    )

    /// 2027–28 brackets are legislated (14% second bracket). Its Schedule 1 formulas aren't
    /// published yet, so the 2026–27 ones are used and the year is marked as an estimate.
    public static let fy2027 = TaxYearData(
        year: FinancialYear(startYear: 2027),
        brackets: [
            TaxBracket(threshold: 0, baseTaxCents: 0, rateBasisPoints: 0),
            TaxBracket(threshold: 18_200, baseTaxCents: 0, rateBasisPoints: 1400),
            TaxBracket(threshold: 45_000, baseTaxCents: 375_200, rateBasisPoints: 3000),
            TaxBracket(threshold: 135_000, baseTaxCents: 3_075_200, rateBasisPoints: 3700),
            TaxBracket(threshold: 190_000, baseTaxCents: 5_110_200, rateBasisPoints: 4500),
        ],
        medicareRateBasisPoints: 200,
        medicareLowIncomeThreshold: 28_011,
        medicareShadeInBasisPoints: 1000,
        lowIncomeTaxOffset: lito,
        superGuaranteeBasisPoints: 1200,
        maxContributionBase: .dollars(270_830),
        concessionalCap: .dollars(32_500),
        standardDeduction: .dollars(1000),
        scale1: scale1From2026,
        scale2: scale2From2026,
        isEstimate: true,
        notes: ["2027–28 withholding uses the 2026–27 formulas until the ATO publishes new ones.",
                "Super caps and the Medicare threshold are carried over from 2026–27."]
    )

    /// The data for a financial year. Years without their own data borrow the nearest
    /// known year and are marked as estimates.
    public static func data(for year: FinancialYear) -> TaxYearData {
        switch year.startYear {
        case 2026:
            return fy2026
        case 2027:
            return fy2027
        case ..<2026:
            var data = fy2026
            data.year = year
            data.isEstimate = true
            data.notes = ["Using 2026–27 rates for \(year.label)."]
            return data
        default:
            var data = fy2027
            data.year = year
            data.isEstimate = true
            data.notes = ["Using 2027–28 rates for \(year.label); later changes aren't known yet."]
            return data
        }
    }

    public static func data(for date: LocalDate) -> TaxYearData {
        data(for: date.financialYear)
    }
}
