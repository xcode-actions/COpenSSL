// swift-tools-version:5.5
import PackageDescription


let package = Package(
	name: "COpenSSL",
	platforms: [
		.macOS(.v11) /* Technically .v12 */
	],
	products: [
		.executable(name: "build-openssl-framework", targets: ["build-framework"])
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-argument-parser.git", .branch("async")),
		.package(url: "https://github.com/happn-tech/XibLoc.git", from: "1.1.1"),
		.package(url: "https://github.com/xcode-actions/clt-logger.git", from: "0.3.4"),
		.package(url: "https://github.com/xcode-actions/swift-signal-handling.git", from: "0.2.0"),
		.package(url: "https://github.com/xcode-actions/XcodeTools.git", from: "0.3.5")
	],
	targets: [
		.executableTarget(name: "build-framework", dependencies: [
			.product(name: "ArgumentParser", package: "swift-argument-parser"),
			.product(name: "CLTLogger",      package: "clt-logger"),
			.product(name: "SignalHandling", package: "swift-signal-handling"),
			.product(name: "XcodeTools",     package: "XcodeTools"),
			.product(name: "XibLoc",         package: "XibLoc")
		])
	]
)
