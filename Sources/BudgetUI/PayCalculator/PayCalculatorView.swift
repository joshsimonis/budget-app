import BudgetCore
import SwiftUI

/// Work out take-home pay from a yearly, monthly, fortnightly, weekly or daily rate.
struct PayCalculatorView: View {
    @State private var amount = Money.dollars(100_000)
    @State private var unit: RateUnit = .annual
    @State private var superMode: SuperMode = .onTop
    @State private var kind: EmploymentKind = .salaried
    @State private var workDays = 5
    @State private var claimsThreshold = true
    @State private var sacrifice = Money.zero
    @State private var afterTax = Money.zero
    @State private var gst = false
    @State private var standardDeduction = true
    @State private var yearStart = LocalDate(pickerDate: Date()).financialYear.startYear

    private var quote: PayQuote {
        PayQuote.make(PayQuoteInput(
            amount: amount, unit: unit, superMode: superMode, kind: kind, workDaysPerWeek: workDays,
            claimsTaxFreeThreshold: claimsThreshold, salarySacrificePerYear: sacrifice, afterTaxSuperPerYear: afterTax,
            gstRegistered: gst, applyStandardDeduction: standardDeduction, year: FinancialYear(startYear: yearStart)
        ))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section("Pay") {
                    Picker("Type", selection: $kind) {
                        ForEach(EmploymentKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Amount") {
                        MoneyField(title: "Amount", value: $amount).frame(width: 130)
                    }
                    Picker("Per", selection: $unit) {
                        ForEach(RateUnit.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if kind != .abn {
                        Picker("Super", selection: $superMode) {
                            Text("On top").tag(SuperMode.onTop)
                            Text("Included (package)").tag(SuperMode.included)
                        }
                    }
                    Stepper("\(workDays) work days a week", value: $workDays, in: 1...7)
                }
                Section("Tax") {
                    Picker("Tax year", selection: $yearStart) {
                        ForEach([2026, 2027], id: \.self) { year in
                            Text(FinancialYear(startYear: year).label).tag(year)
                        }
                    }
                    if kind == .abn {
                        Toggle("Registered for GST", isOn: $gst)
                    } else {
                        Toggle("Claim the tax-free threshold", isOn: $claimsThreshold)
                    }
                    Toggle("$1,000 standard deduction", isOn: $standardDeduction)
                }
                Section("Extra super (per year)") {
                    LabeledContent(kind == .abn ? "Deductible contributions" : "Salary sacrifice") {
                        MoneyField(title: "Pre-tax", value: $sacrifice).frame(width: 110)
                    }
                    if kind != .abn {
                        LabeledContent("After-tax contributions") {
                            MoneyField(title: "After tax", value: $afterTax).frame(width: 110)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 360)
            Divider()
            results
        }
        .frame(minWidth: 940, minHeight: 560)
        .navigationTitle("Pay Calculator")
    }

    private var results: some View {
        let quote = quote
        let isABN = kind == .abn
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if quote.input.superMode == .included && !isABN {
                    Text("Package \(Format.money(quote.annualQuoted)) a year = \(Format.money(quote.annualBase)) salary + \(Format.money(quote.annualSuperGuarantee)) super")
                        .foregroundStyle(.secondary)
                }
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        header(isABN ? "Fee" : "Gross")
                        header(isABN ? "Super" : "Sacrifice")
                        header(isABN ? "GST" : "Tax")
                        header(isABN ? "Received" : "Take-home")
                        header(isABN ? "Set aside" : "Employer super")
                    }
                    Divider().gridCellColumns(6)
                    ForEach(quote.rows) { row in
                        let b = row.breakdown
                        GridRow {
                            Text(row.label).fontWeight(.medium)
                            value(b.gross)
                            value(b.salarySacrifice)
                            value(isABN ? b.gst : b.withholding)
                            value(b.net, bold: true)
                            value(isABN ? b.taxSetAside + b.gstSetAside : b.superGuarantee)
                        }
                    }
                }
                Text(isABN
                     ? "Set aside = this payment's share of the year's tax, plus the GST. Spendable each week: \(Format.money(quote.rows[0].breakdown.spendable))."
                     : "Per-pay tax is what your employer withholds (ATO Schedule 1). The yearly row uses the actual tax for the year.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GroupBox("Tax for \(quote.data.year.label)") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        line("Taxable income", quote.annualTax.taxableIncome)
                        if quote.standardDeduction.isPositive { line("Includes standard deduction", -quote.standardDeduction) }
                        line("Income tax", quote.annualTax.incomeTax)
                        if quote.annualTax.lowIncomeTaxOffset.isPositive { line("Low income tax offset", -quote.annualTax.lowIncomeTaxOffset) }
                        line("Medicare levy", quote.annualTax.medicareLevy)
                        line("Total tax", quote.annualTax.total, bold: true)
                        if !isABN {
                            line("Withheld if paid weekly", quote.annualWithheldIfWeekly)
                            line(quote.expectedRefund.isNegative ? "Likely to owe" : "Likely refund", quote.expectedRefund.magnitude)
                        }
                        line("Super (employer + yours)", quote.concessionalContributions)
                    }
                    .padding(6)
                }
                if quote.exceedsConcessionalCap {
                    Label("That's over the \(Format.wholeDollars(quote.data.concessionalCap)) concessional contributions cap.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if !quote.data.notes.isEmpty {
                    Text(quote.data.notes.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func value(_ amount: Money, bold: Bool = false) -> some View {
        Text(amount.isZero ? "–" : Format.money(amount))
            .monospacedDigit()
            .fontWeight(bold ? .semibold : .regular)
    }

    private func line(_ title: String, _ amount: Money, bold: Bool = false) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(Format.money(amount))
                .monospacedDigit()
                .fontWeight(bold ? .semibold : .regular)
                .gridColumnAlignment(.trailing)
        }
    }
}
