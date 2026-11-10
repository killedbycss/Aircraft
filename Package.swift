// swift-tools-version: 6.0
import PackageDescription

// Приложение собирается с последним установленным SDK (сейчас macOS 27),
// но запускается и на более старых системах — минимум macOS 15, то есть
// и на macOS 26 тоже. Новые API macOS 27 нужно оборачивать в
// `if #available(macOS 27, *) { … } else { … }`, чтобы на 26 работал фолбэк.
let minimumMacOS = "15.0"

// SwiftPM записывает в бинарник версию SDK, равную минимальной системе (15.0),
// из-за чего AppKit включает режим совместимости со старым SDK. Явно указываем
// линковщику реальную версию SDK, чтобы на macOS 27 включалось новое поведение.
let sdkVersion = "27.0"

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
            exclude: ["Assets.xcassets"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-platform_version",
                    "-Xlinker", "macos",
                    "-Xlinker", minimumMacOS,
                    "-Xlinker", sdkVersion
                ])
            ]
        ),
        .testTarget(
            name: "AircraftTests",
            dependencies: ["aircraft"]
        )
    ]
)
