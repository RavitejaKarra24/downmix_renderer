// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Downmix",
  platforms: [
    .macOS(.v15)
  ],
  targets: [
    .executableTarget(
      name: "Downmix",
      path: "Sources/Downmix"
    )
  ]
)
