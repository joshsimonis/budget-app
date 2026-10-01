# Budget

A native macOS cash-flow planner for Australians who bank with [Up](https://up.com.au).

Plan recurring bills, envelopes and one-offs, work out take-home pay (PAYG, day-rate or ABN, super included or on top), and see a running cash total by day, week or month. Up Bank sync checks the plan against what actually happened.

> Work in progress. See the milestones in the plan; this README gets the full install guide when the app is usable.

## Privacy

This repository is public. The app keeps your budget in `~/Library/Application Support/Budget/` and your Up token in the macOS Keychain. Nothing personal belongs in this repo, and all test and sample data is made up.

## Building

- **Xcode:** open `Package.swift`, pick the `Budget` scheme, press Run.
- **Terminal:** `scripts/build-app.sh` builds `build/Budget.app` (needs macOS 15 and Xcode or the Command Line Tools).
- **Tests:** `swift test`. The `BudgetCore` and `UpAPI` modules also build and test on Linux.
