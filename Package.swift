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
		.binaryTarget(name: "COpenSSL-static", url: "https://github.com/xcode-actions/COpenSSL/releases/download/1.1.114/COpenSSL-static.xcframework.zip", checksum: "20d5b0c3ca31a9bad325208e42ee8aeac729f1ba5d4067ec07bb92beff5761f6"),
		.binaryTarget(name: "COpenSSL-dynamic", url: "https://github.com/xcode-actions/COpenSSL/releases/download/1.1.114/COpenSSL-dynamic.xcframework.zip", checksum: "1ff09aaa3225e3aec3efe541a874c8b1907d828f6ed65257c905a404bfc655b5")
	]
)
