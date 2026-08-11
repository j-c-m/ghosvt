// swift-tools-version: 6.0
import PackageDescription

let ghosttyInclude = "Vendor/ghostty/zig-out/include"
let ghosttyStatic = "Vendor/ghostty/zig-out/lib/libghostty-vt.a"

let package = Package(
    name: "Ghosvt",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ghosvt", targets: ["Ghosvt"]),
    ],
    targets: [
        .target(
            name: "CGhosttyVT",
            path: "Sources/CGhosttyVT",
            exclude: ["ghostty-vt.pc"],
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("../../\(ghosttyInclude)"),
                .define("GHOSTTY_STATIC"),
                .unsafeFlags(["-I\(ghosttyInclude)"]),
            ],
            linkerSettings: [
                .linkedLibrary("util"),
                .unsafeFlags([
                    "-LVendor/ghostty/zig-out/lib",
                    "-Xlinker", "-force_load",
                    "-Xlinker", ghosttyStatic,
                ]),
            ]
        ),
        .executableTarget(
            name: "Ghosvt",
            dependencies: ["CGhosttyVT"],
            path: "Sources/Ghosvt",
            resources: [
                .copy("Resources"),
            ],
            cSettings: [
                .define("GHOSTTY_STATIC"),
                .unsafeFlags(["-I\(ghosttyInclude)"]),
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-Xcc", "-I\(ghosttyInclude)",
                    "-Xcc", "-DGHOSTTY_STATIC",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ImageIO"),
                .linkedFramework("WebKit"),
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
