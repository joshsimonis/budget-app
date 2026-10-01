// swift-tools-version: 6.0
import PackageDescription

// BudgetCore and UpAPI are plain Foundation code that builds and tests on Linux too.
// The SwiftUI app targets only exist when building on macOS.
var products: [Product] = [
    .library(name: "BudgetCore", targets: ["BudgetCore"]),
    .library(name: "UpAPI", targets: ["UpAPI"]),
]

var targets: [Target] = [
    .target(name: "BudgetCore"),
    .target(name: "UpAPI", dependencies: ["BudgetCore"]),
    .testTarget(
        name: "BudgetCoreTests",
        dependencies: ["BudgetCore"],
        resources: [.copy("Fixtures")]
    ),
    .testTarget(
        name: "UpAPITests",
        dependencies: ["UpAPI", "BudgetCore"],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
let uiSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]
products.append(.executable(name: "Budget", targets: ["BudgetApp"]))
targets += [
    .target(name: "BudgetUI", dependencies: ["BudgetCore", "UpAPI"], swiftSettings: uiSettings),
    .executableTarget(name: "BudgetApp", dependencies: ["BudgetUI"], swiftSettings: uiSettings),
    .testTarget(name: "BudgetUITests", dependencies: ["BudgetUI", "BudgetCore"], swiftSettings: uiSettings),
]
#endif

let package = Package(
    name: "Budget",
    platforms: [.macOS(.v15)],
    products: products,
    targets: targets
)
