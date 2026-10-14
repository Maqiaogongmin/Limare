// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "OpenMinisProviders", platforms: [.macOS("15.0")], products: [.library(name: "OpenMinisProviders", targets: ["OpenMinisProviders"])], dependencies: [.package(url: "https://github.com/jamesrochabrun/SwiftAnthropic", exact: "2.2.2")], targets: [.target(name: "OpenMinisProviders", dependencies: [.product(name: "SwiftAnthropic", package: "SwiftAnthropic")]), .testTarget(name: "OpenMinisProvidersTests", dependencies: ["OpenMinisProviders"])])
