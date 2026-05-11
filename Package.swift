// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Summarizo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Summarizo", targets: ["Summarizo"])
    ],
    dependencies: [
        .package(url: "https://github.com/carbocation/CarbocationLocalLLM.git", exact: "0.23.0")
    ],
    targets: [
        .executableTarget(
            name: "Summarizo",
            dependencies: [
                .product(name: "CarbocationLocalLLM", package: "CarbocationLocalLLM"),
                .product(name: "CarbocationLocalLLMRuntime", package: "CarbocationLocalLLM"),
                .product(name: "CarbocationLocalLLMRuntimeUI", package: "CarbocationLocalLLM")
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "SummarizoTests",
            dependencies: ["Summarizo"]
        )
    ]
)
