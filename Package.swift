// swift-tools-version:5.3
import PackageDescription


/* Binary package definition for COpenSSL. */

let package = Package(
	name: "COpenSSL",
	products: [
		/* Sadly the line below does not work. The idea was to have a
		 * library where SPM chooses whether to take the dynamic or static
		 * version of the target, but it fails (Xcode 12B5044c). */
//		.library(name: "COpenSSL", targets: ["COpenSSL-static", "COpenSSL-dynamic"]),
//		.library(name: "COpenSSL-static", targets: ["COpenSSL-static"]),
		.library(name: "COpenSSL-dynamic", targets: ["COpenSSL-dynamic"])
	],
	targets: [
//		.binaryTarget(name: "COpenSSL-static", url: "https://github.com/xcode-actions/COpenSSL/releases/download/1.1.111/COpenSSL-static.xcframework.zip", checksum: "f93578dd55004b8454dc771166a911e82f91e98aad636f9d1556b67a02ee5a48"),
		.binaryTarget(name: "COpenSSL-dynamic", url: "https://github.com/xcode-actions/COpenSSL/releases/download/1.1.111/COpenSSL-dynamic.xcframework.zip", checksum: "18a82ef2a2188955e99f0089572760c7f70cb9b2d79ccf928fe5464885af8703")
	]
)
