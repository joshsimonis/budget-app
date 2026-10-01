# Budget

A native macOS cash-flow planner for Australians who bank with [Up](https://up.com.au).

You plan bills, envelopes, one-offs and pay. Budget shows a running cash total by day, week or month, works out take-home pay and tax, and checks the plan against your Up transactions so you know what's been paid.

## What it does

- **Bills and spending**
  - Weekly, fortnightly, every N days/weeks/months, monthly (including the last day), quarterly or yearly.
  - Weekend and public-holiday rules.
  - Price changes from a date ("the insurance goes up in March").
  - One-off expenses and one-off money in (selling something).
- **Envelopes** for flexible spending such as groceries. They track the Up categories or tags you pick, show spent vs left, and project whichever is higher: the budget or what you've actually spent.
- **Income and tax**
  - Salaried, day-rate through payroll, or ABN contractor, and several jobs at once.
  - Rates entered per year, month, fortnight, week or day, with super on top or included.
  - ATO PAYG withholding, the Medicare levy, the low income tax offset, salary sacrifice and after-tax super.
  - For ABN work, GST and income tax set aside.
  - Pay rises, a new job starting or an old one ending, unpaid leave, days actually worked, missed pays, and the amount you actually received.
  - A yearly estimate shows whether you're heading for a refund or a bill, and whether you're over the super cap.
- **Periods** like Travel. Over a date range they pause chosen items, add their own lines, and can mark your pay as unpaid.
- **Cash Flow grid** like a spreadsheet:
  - Rows grouped by account, columns by day, week or month.
  - Period bands and this week highlighted.
  - A running balance chart.
  - Click any cell to change, skip or move that occurrence, or change the amount from that date on.
- **Up Bank**
  - Uses your real balance and the last 13 months of transactions.
  - Ticks off bills automatically, flags anything overdue, and lists spending that isn't in the plan.
  - Suggests regular payments and envelope amounts from your history.
- **Pay Calculator** window (⇧⌘P) for any salary, rate or package.

## Install

You need macOS 15 Sequoia or later.

**Option 1: download the app from GitHub Actions.**
1. Open the latest green run under *Actions* (CI) and download the **Budget-app** artifact.
2. Unzip it and move `Budget.app` to Applications.
3. The app isn't notarised, so the first time you open it go to *System Settings › Privacy & Security* and click **Open Anyway**. Or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Budget.app
   ```

**Option 2: build it yourself.** You need Xcode or the Xcode Command Line Tools.
```sh
git clone https://github.com/joshsimonis/budget-app.git
cd budget-app
scripts/build-app.sh            # build/Budget.app (Apple Silicon + Intel)
ARCHS=arm64 scripts/build-app.sh  # faster, Apple Silicon only
open build/Budget.app
```
You can also open `Package.swift` in Xcode and run the `Budget` scheme.

**Try it with sample data:**
```sh
open build/Budget.app --args --demo
```
This uses a made-up budget and made-up bank activity in a scratch folder. Your real budget isn't touched.

## Connecting Up

1. Create a personal access token in the Up app (**Data sharing › Personal Access Token**) or at [api.up.com.au](https://api.up.com.au/getting_started).
2. In Budget open **Settings › Up Bank**, paste the token and click **Connect**.
3. Untick any saver you don't want counted in your running balance (long-term savings, for example).

About the token and syncing:
- The token is stored in your login Keychain and only ever sent to `api.up.com.au`.
- Budget syncs when it starts, every 15 minutes while it's open, when your Mac wakes, and when you press ⌘R.
- Because the app is ad-hoc signed, macOS may ask once per new build whether Budget can use the Keychain item. Choose **Always Allow**.

**To have a bill ticked off automatically**, give it matching text: words from the Up description, such as `telstra`. Suggestions fill this in for you. Items without matching text are assumed paid once their date has passed.

## How the numbers work

- **Running balance**
  - **With Up:** today's balance is the total of the Up accounts you count. Past days are worked backwards from your transactions. Future days add what's still planned. Bills already paid (even early) aren't counted twice.
  - **Without Up:** enter a balance you know in the *Bank balance* row. The running total restarts from it, like typing your actual bank balance into a spreadsheet.
- **Overdue items** stay *pending* (still expected today) for 4 days, then show as *missed* and are left out until you link a transaction or mark them paid. You can change the 4 days in Settings.
- **Pay in arrears:** "each pay covers work up to N days before pay day". A Wednesday pay for the week ending Sunday is N = 3. Days off show up in the following pay.
- **Public holidays** are Victorian. Day-rate pays leave them out. Salaried pays include them. Add or remove days in Settings › Holidays.
- **Tax figures** are the 2026–27 ATO rates, and 2027–28 brackets where they're law. Withholding uses the ATO Schedule 1 formulas. Some figures are assumed until the ATO publishes them (the 2026–27 Medicare low-income threshold, and 2027–28 withholding). These are flagged in the app. Check anything important against [ato.gov.au](https://www.ato.gov.au).

## Your data and privacy

- Your budget is saved in `~/Library/Application Support/Budget/budget.json`.
- Backups are kept hourly while you make changes, up to 20 (Settings › Data).
- Up data is cached next to it in `up-cache.json`.
- **This repository is public.** Nothing personal belongs in it. All test and sample data is made up, and CI fails if anything that looks like an Up token is committed.

## Development

| Module | What's in it |
|---|---|
| `Sources/BudgetCore` | Dates, money, recurrence, holidays, tax, the projection, reconciliation and suggestions. Foundation only, so it also builds on Linux. |
| `Sources/UpAPI` | The Up client and sync. |
| `Sources/BudgetUI` and `Sources/BudgetApp` | The SwiftUI app (macOS only). |

```sh
swift test   # all tests (BudgetCore and UpAPI also run on Linux)
```

CI runs the core tests on Linux (Swift 6.0 and 6.2) and builds and tests the app on macOS. It uploads `Budget.zip` and demo screenshots as artifacts.

In a Linux container without Swift, `scripts/bootstrap-linux-swift.sh` installs a toolchain from Ubuntu's packages.
