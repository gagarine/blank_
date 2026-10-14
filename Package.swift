// swift-tools-version: 6.0
import PackageDescription
import Foundation

let checks = ProcessInfo.processInfo.environment["BLANK_BUILD_CHECKS"] == "1"
let verificationSettings: [SwiftSetting] = checks ? [.unsafeFlags(["-enable-testing"])] : []

let package = Package(
    name: "blank_", platforms: [.macOS("27.0")],
    products: [.executable(name: "blank_", targets: ["BlankApp"])],
    targets: [
        .systemLibrary(name: "CTypst", path: "Sources/CTypst"),
        .target(name: "BlankCore", dependencies: ["CTypst"], linkerSettings: [
            .unsafeFlags(["-Ltarget/release", "-lblank_syntax", "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
        ]),
        .target(name: "BlankNative", dependencies: ["BlankCore"], swiftSettings:verificationSettings),
        .executableTarget(name: "BlankApp", dependencies: ["BlankNative"]),
        .testTarget(name: "BlankUnitTests", dependencies: ["BlankCore"], path: "Tests/Unit")
    ] + (checks ? [
        .target(name:"BlankTestSupport",path:"Tests/Support"),
        .target(name:"BlankIntegrationTests",dependencies:["BlankNative","BlankTestSupport"],path:"Tests/Integration",exclude:["Runner","CompilerProtocolChecks.py"],swiftSettings:verificationSettings),
        .executableTarget(name:"BlankIntegrationChecks",dependencies:["BlankIntegrationTests"],path:"Tests/Integration/Runner"),
        .target(name:"BlankUITests",dependencies:["BlankNative","BlankIntegrationTests","BlankTestSupport"],path:"Tests/UI",exclude:["Runner"],swiftSettings:verificationSettings),
        .executableTarget(name:"BlankUIChecks",dependencies:["BlankUITests"],path:"Tests/UI/Runner")
    ] : []), swiftLanguageModes: [.v5]
)
