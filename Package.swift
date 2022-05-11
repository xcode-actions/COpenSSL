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
		.binaryTarget(name: "COpenSSL-static", url: "https://github.com/xcode-actions/COpenSSL/releases/download/1.1.115/COpenSSL-static.xcframework.zip", checksum: "8d09886b37329154302a0f6887644201d307b627badd78d4d6fdfdcac39e06dd"),
		.binaryTarget(name: "COpenSSL-dynamic", url: "https://github.com/xcode-actions/COpenSSL/releases/download/1.1.115/COpenSSL-dynamic.xcframework.zip", checksum: "3a6ea19ad5db2c554f24874e89bdac086cf7f907a73519adb8bb8addf50f2a34")
	]
)
