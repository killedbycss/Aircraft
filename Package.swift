// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aircraft",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Aircraft", targets: ["aircraft"])
    ],
    targets: [
        .executableTarget(
            name: "aircraft",
            path: "Sources/EasyBrowser",
            exclude: ["Assets.xcassets"]
        ),
        .testTarget(
            name: "AircraftTests",
            dependencies: ["aircraft"]
        )
    ]
)
