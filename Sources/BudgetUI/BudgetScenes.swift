import AppKit
import SwiftUI

/// All of the app's scenes. `BudgetApp` (the executable) only hosts these.
public struct BudgetScenes: Scene {
    public init() {}

    public var body: some Scene {
        WindowGroup("Budget") {
            Text("Budget")
                .font(.largeTitle)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

/// Makes the app behave like a normal Dock app even when it is launched as a bare
/// executable from Xcode or `swift run` (no .app bundle around it).
public final class BudgetAppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
