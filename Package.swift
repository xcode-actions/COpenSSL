// swift-tools-version:5.5
import PackageDescription


let package = Package(
	name: "COpenSSL",
	platforms: [
		.macOS(.v12)
	],
	products: [
		.executable(name: "build-openssl-framework", targets: ["build-framework"])
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0"),
		.package(url: "https://github.com/happn-app/XibLoc.git", from: "1.1.1"),
		.package(url: "https://github.com/xcode-actions/clt-logger.git", from: "0.3.6"),
		.package(url: "https://github.com/xcode-actions/swift-signal-handling.git", from: "1.0.0"),
		.package(url: "https://github.com/xcode-actions/XcodeTools.git", branch: "develop+spmcompat")
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
