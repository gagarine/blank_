// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "blank_", platforms: [.macOS(.v14)],
    products: [.executable(name: "blank_", targets: ["BlankNative"])],
    targets: [
        .systemLibrary(name: "CTypst", path: "Sources/CTypst"),
        .target(name: "BlankCore", dependencies: ["CTypst"], linkerSettings: [
            .unsafeFlags(["-Ltypst-syntax-bridge/target/release", "-lblank_syntax", "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
        ]),
        .executableTarget(name: "BlankNative", dependencies: ["BlankCore"]),
        .executableTarget(name: "BlankCoreChecks", dependencies: ["BlankCore"], path: "Tests/BlankCoreTests")
    ], swiftLanguageModes: [.v5]
)
