import SwiftUI
import Testing
@testable import BudgetUI

@MainActor
@Test func rendersPlaceholderView() {
    let renderer = ImageRenderer(content: Text("Budget").frame(width: 200, height: 100))
    #expect(renderer.cgImage != nil)
}
