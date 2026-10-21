// swift-tools-version:5.9
// Modified by Jon Hammant, 2026, as part of Porthole (see NOTICE).
import PackageDescription

let package = Package(
    name: "Porthole",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "StreamProtocol", targets: ["StreamProtocol"]),
        // The CLI keeps the product name PortholeHost, so `swift run -c release PortholeHost …` and
        // .build/release/PortholeHost are what they always were.
        .executable(name: "PortholeHost", targets: ["PortholeHostCLI"]),
        // Porthole.app's executable. Scripts/make-app.sh wraps it into the bundle and signs it.
        .executable(name: "PortholeMenuBar", targets: ["PortholeMenuBar"]),
        // No product for PortholeHostCore: the iOS project links this package and must never see it.
    ],
    // Porthole: a terminal emulator for the text modes (docs/agent-view-plan.md): the host reads Claude's
    // agent view through it. MIT; the one package Porthole takes besides Apple's.
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0"),
    ],
    targets: [
        .target(name: "StreamProtocol"),
        // The Mac host itself (capture, encode, network, input, virtual display), shared by the CLI
        // and the menu bar app; they reach it through `package` access. The folder keeps its old
        // name (Sources/PortholeHost) so the paths in the docs and the VirtualDisplayProbe symlink to
        // ../PortholeHost/VirtualDisplay.swift stay valid.
        .target(name: "PortholeHostCore", dependencies: ["StreamProtocol", .product(name: "SwiftTerm", package: "SwiftTerm")],
                path: "Sources/PortholeHost"),
        // The command-line host: flags, the run loop, the Terminal permission hint.
        .executableTarget(name: "PortholeHostCLI", dependencies: ["PortholeHostCore", "StreamProtocol"]),
        // The menu bar app: status item, Settings and Log windows (AppKit lifecycle, SwiftUI panes).
        .executableTarget(name: "PortholeMenuBar", dependencies: ["PortholeHostCore", "StreamProtocol"]),
        // Milestone 3 spike: virtual display + window move + capture. Its VirtualDisplay.swift
        // is a symlink to the host's copy. Not shipped.
        // Porthole: runs Porthole's AppleScript on its own main thread, off the host's (PortholeTerminal.swift).
        .executableTarget(name: "PortholeOSAHelper"),
        .executableTarget(name: "CaptureProbe"),
        .executableTarget(name: "VirtualDisplayProbe"),
    ]
)
