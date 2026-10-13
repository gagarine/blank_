// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "blank_", platforms: [.macOS("27.0")],
    products: [.executable(name: "blank_", targets: ["BlankNative"])],
    targets: [
        .systemLibrary(name: "CTypst", path: "Sources/CTypst"),
        .target(name: "BlankCore", dependencies: ["CTypst"], linkerSettings: [
            .unsafeFlags(["-Ltarget/release", "-lblank_syntax", "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
        ]),
        .executableTarget(name: "BlankNative", dependencies: ["BlankCore"]),
        .testTarget(name: "BlankUnitTests", dependencies: ["BlankCore"], path: "Tests/Unit")
    ], swiftLanguageModes: [.v5]
)
