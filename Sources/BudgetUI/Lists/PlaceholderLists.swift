import BudgetCore
import SwiftUI

struct ItemsListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.document.items) { item in
            VStack(alignment: .leading) {
                Text(item.name)
                Text(GridBuilder.itemSubtitle(item, today: model.today)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Bills & Spending")
    }
}

struct IncomeListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.document.incomes) { income in
            Text(income.name)
        }
        .navigationTitle("Income")
    }
}

struct PeriodsListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.document.periods) { period in
            Text(period.name)
        }
        .navigationTitle("Periods")
    }
}
