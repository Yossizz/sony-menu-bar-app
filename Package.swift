// swift-tools-version:5.10
import Foundation
import PackageDescription

// Absolute paths so the C headers and prebuilt static libs resolve regardless of cwd.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendor = "\(root)/vendor/SonyHeadphonesClient"

// Every Swift target that (transitively) imports CMDR needs the libmdr include paths.
let mdrHeaders: [SwiftSetting] = [
    .unsafeFlags([
        "-Xcc", "-I\(vendor)/libmdr/include",
        "-Xcc", "-I\(vendor)/libmdr-bt/include",
    ]),
]

let package = Package(
    name: "xm-menubar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "xmctl", targets: ["xmctl"]),
        .executable(name: "XMBar", targets: ["XMBar"]),
    ],
    targets: [
        // C API of libmdr + the macOS IOBluetooth backend (built by scripts/build-libmdr.sh).
        .systemLibrary(name: "CMDR", path: "Sources/CMDR"),

        // Swift helpers over libmdr shared by the CLI and the app.
        .target(
            name: "XMKit",
            dependencies: ["CMDR"],
            swiftSettings: mdrHeaders,
            linkerSettings: [
                .unsafeFlags(["-L\(root)/build/lib"]),
                .linkedLibrary("mdr-bt"),
                .linkedLibrary("mdr"),
                .linkedLibrary("fmt"),
                .linkedLibrary("c++"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Foundation"),
            ]
        ),

        // Phase 0 command-line tool.
        .executableTarget(
            name: "xmctl",
            dependencies: ["XMKit"],
            exclude: ["Info.plist"],
            swiftSettings: mdrHeaders,
            linkerSettings: [
                // Embed an Info.plist so macOS has a Bluetooth usage string for this CLI.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist", "-Xlinker", "\(root)/Sources/xmctl/Info.plist",
                ]),
            ]
        ),

        // Menu bar app. Packaged into XMBar.app by scripts/bundle-app.sh (uses Sources/XMBar/Info.plist).
        .executableTarget(
            name: "XMBar",
            dependencies: ["XMKit"],
            exclude: ["Info.plist"],
            swiftSettings: mdrHeaders
        ),
    ]
)
