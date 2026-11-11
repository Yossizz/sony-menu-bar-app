// swift-tools-version:5.10
import Foundation
import PackageDescription

// Absolute paths so the C headers and prebuilt static libs resolve regardless of cwd.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendor = "\(root)/vendor/SonyHeadphonesClient"

let package = Package(
    name: "xm-menubar",
    platforms: [.macOS(.v13)],
    targets: [
        // C API of libmdr + the macOS IOBluetooth backend (built by scripts/build-libmdr.sh).
        .systemLibrary(name: "CMDR", path: "Sources/CMDR"),
        .executableTarget(
            name: "xmctl",
            dependencies: ["CMDR"],
            exclude: ["Info.plist"],
            swiftSettings: [
                .unsafeFlags([
                    "-Xcc", "-I\(vendor)/libmdr/include",
                    "-Xcc", "-I\(vendor)/libmdr-bt/include",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(root)/build/lib",
                    // Embed an Info.plist so macOS has a Bluetooth usage string for this CLI.
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist", "-Xlinker", "\(root)/Sources/xmctl/Info.plist",
                ]),
                .linkedLibrary("mdr-bt"),
                .linkedLibrary("mdr"),
                .linkedLibrary("fmt"),
                .linkedLibrary("c++"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Foundation"),
            ]
        ),
    ]
)
