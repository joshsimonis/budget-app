import BudgetUI
import SwiftUI

@main
struct BudgetMain: App {
    @NSApplicationDelegateAdaptor(BudgetAppDelegate.self) private var appDelegate

    var body: some Scene {
        BudgetScenes()
    }
}
