// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleAvailabilityApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AppleAvailabilityApp", targets: ["AppleAvailabilityApp"])
    ],
    targets: [
        .executableTarget(
            name: "AppleAvailabilityApp",
            path: "Sources/AppleAvailabilityApp"
        )
    ]
)
