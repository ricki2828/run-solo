// swift-tools-version:5.9
// K0 spike: a Swift XCTest calling the Kotlin facade through the XCFramework. CI copies
// RunCore.xcframework here from spike/kmp-core/build/XCFrameworks/release before building.
import PackageDescription

let package = Package(
    name: "RunCoreSmoke",
    platforms: [.iOS(.v17), .macOS(.v14)],
    targets: [
        .binaryTarget(name: "RunCore", path: "RunCore.xcframework"),
        .testTarget(name: "RunCoreSmokeTests", dependencies: ["RunCore"]),
    ]
)
