// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIStat",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AIStatCore", targets: ["AIStatCore"]),
        .executable(name: "AIStat", targets: ["AIStatApp"]),
        // Live smoke test against the real status pages, the counterpart of
        // `cargo run -p aistat-core --example smoke`.
        .executable(name: "aistat-smoke", targets: ["aistat-smoke"]),
        .executable(name: "aistat-preview", targets: ["aistat-preview"]),
    ],
    targets: [
        // Deliberately AppKit-free, the way `crates/core` is Tauri-free: every
        // mapping decision here is unit-testable without a display.
        .target(name: "AIStatCore"),
        // The app's real code, in a library so the test target can import it.
        .target(name: "AIStatUI", dependencies: ["AIStatCore"]),
        .executableTarget(name: "AIStatApp", dependencies: ["AIStatUI"]),
        .executableTarget(name: "aistat-smoke", dependencies: ["AIStatCore"]),
        // Renders the panel and the settings window offscreen, so a layout
        // change can be looked at without launching the app and taking a
        // screenshot of a menu bar.
        .executableTarget(name: "aistat-preview", dependencies: ["AIStatUI"]),
        .testTarget(name: "AIStatCoreTests", dependencies: ["AIStatCore"]),
        .testTarget(name: "AIStatUITests", dependencies: ["AIStatUI"]),
    ]
)
