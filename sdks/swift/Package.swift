// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GuillotineEVM",
    platforms: [
        .macOS(.v12),
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "GuillotineEVM",
            targets: ["GuillotineEVM"]),
    ],
    targets: [
        .target(
            name: "GuillotineC",
            path: "Sources/GuillotineC"
        ),
        .target(
            name: "GuillotinePrimitives",
            dependencies: ["GuillotineC"],
            path: "Sources/GuillotinePrimitives"
        ),
        .target(
            name: "GuillotineCompilers",
            dependencies: ["GuillotinePrimitives"],
            path: "Sources/GuillotineCompilers"
        ),
        .target(
            name: "GuillotineFFI",
            path: "Sources/GuillotineFFI",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L../../zig-out/lib"]),
                .linkedLibrary("guillotine_ffi")
            ]
        ),
        .target(
            name: "GuillotineEVM",
            dependencies: ["GuillotineFFI", "GuillotinePrimitives", "GuillotineC"],
            path: "Sources/GuillotineEVM"
        ),
        .executableTarget(
            name: "BasicTest",
            dependencies: ["GuillotinePrimitives"],
            path: "Sources/BasicTest"
        ),
        .testTarget(
            name: "GuillotineEVMTests",
            dependencies: ["GuillotineEVM"],
            path: "Tests/GuillotineEVMTests"
        ),
        .testTarget(
            name: "GuillotinePrimitivesTests",
            dependencies: ["GuillotinePrimitives"],
            path: "Tests/GuillotinePrimitivesTests"
        ),
        .testTarget(
            name: "GuillotineCompilersTests",
            dependencies: ["GuillotinePrimitives"],
            path: "Tests/GuillotineCompilersTests"
        ),
    ]
)
