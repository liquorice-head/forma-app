// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Forma",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Forma", targets: ["Forma"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [.executableTarget(name: "Forma", dependencies: [.product(name: "Sparkle", package: "Sparkle")], exclude: ["Resources"], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]), .testTarget(name: "FormaTests", dependencies: ["Forma"])],
    swiftLanguageModes: [.v5]
)
