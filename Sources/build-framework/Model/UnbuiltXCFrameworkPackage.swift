import Foundation

import XcodeTools



struct UnbuiltXCFrameworkPackage {
	
	var buildPaths: BuildPaths
	var skipExistingArtifacts: Bool
	
	func buildXCFrameworkPackage(opensslVersion: String) async throws {
		let artifacts = [buildPaths.resultPackageSwift, buildPaths.resultXCFrameworkStaticArchive, buildPaths.resultXCFrameworkDynamicArchive]
		guard !skipExistingArtifacts || !artifacts.reduce(true, { $0 && Config.fm.fileExists(atPath: $1.string) }) else {
			Config.logger.info("Skipping creation of \(artifacts) because they already exists")
			return
		}
		for artifact in artifacts {
			try Config.fm.ensureDirectory(path: artifact.removingLastComponent())
			try Config.fm.ensureFileDeleted(path: artifact)
		}
		
		/* Create the XCFramework archives */
		do {
			/* Change CWD, but should be done in Process calls below */
			let previousCwd = Config.fm.currentDirectoryPath
			Config.fm.changeCurrentDirectoryPath(buildPaths.resultPackageSwift.removingLastComponent().string)
			defer {Config.fm.changeCurrentDirectoryPath(previousCwd)}
			
			/* TODO: Do not force unwrap here */
			let pi1 = ProcessInvocation("zip", "-r", "--symlinks", buildPaths.resultXCFrameworkStaticArchive.string,  buildPaths.resultXCFrameworkStatic.lastComponent!.string)
			let pi2 = ProcessInvocation("zip", "-r", "--symlinks", buildPaths.resultXCFrameworkDynamicArchive.string, buildPaths.resultXCFrameworkDynamic.lastComponent!.string)
			try await pi1.invokeAndStreamOutput{ line, _, _ in Config.logger.info("zip: fd=\(line.fd): \(line.strLineOrHex())") }
			try await pi2.invokeAndStreamOutput{ line, _, _ in Config.logger.info("zip: fd=\(line.fd): \(line.strLineOrHex())") }
		}
		
		/* Write the package once, without checksums */
		var checksums: [String: String?] = ["static": nil, "dynamic": nil]
		try packageFile(forVersion: nil, checksums: checksums)
			.write(to: buildPaths.resultPackageSwift.url, atomically: true, encoding: .utf8)
		
		do {
			/* Change CWD, but should be done in Process calls below */
			let previousCwd = Config.fm.currentDirectoryPath
			Config.fm.changeCurrentDirectoryPath(buildPaths.resultPackageSwift.removingLastComponent().string)
			defer {Config.fm.changeCurrentDirectoryPath(previousCwd)}
			
			/* Compute checksums */
			struct MoreThanOneLineOfOutput : Error {}
			checksums["static"]  = try await ProcessInvocation("swift", "package", "compute-checksum", buildPaths.resultXCFrameworkStaticArchive.string).invokeAndGetStdout().onlyElement.get(orThrow: MoreThanOneLineOfOutput())
			checksums["dynamic"] = try await ProcessInvocation("swift", "package", "compute-checksum", buildPaths.resultXCFrameworkDynamicArchive.string).invokeAndGetStdout().onlyElement.get(orThrow: MoreThanOneLineOfOutput())
		}
		
		/* Rewrite Package.swift file for remote xcframework */
		try packageFile(forVersion: opensslVersion, checksums: checksums)
			.write(to: buildPaths.resultPackageSwift.url, atomically: true, encoding: .utf8)
	}
	
	func packageFile(forVersion version: String?, checksums: [String: String?]) -> String {
		let types = checksums.keys.sorted(by: { $0.count < $1.count })
		
		var packageString = """
			// swift-tools-version:5.3
			import PackageDescription
			
			
			/* Binary package definition for \(buildPaths.productName). */
			
			let package = Package(
				name: "\(buildPaths.productName)",
				products: [
					/* Sadly the line below does not work. The idea was to have a
					 * library where SPM chooses whether to take the dynamic or static
					 * version of the target, but it fails (Xcode 12B5044c). */
			//		.library(name: "\(buildPaths.productName)", targets: [
			"""
		
		packageString.append(types.map{ #""\#(buildPaths.productName)-\#($0)""# }.joined(separator: ", ") + "]),\n")
		packageString.append(types.map{ #"\#t\#t.library(name: "\#(buildPaths.productName)-\#($0)", targets: ["\#(buildPaths.productName)-\#($0)"])"# }.joined(separator: ",\n") + "\n")
		packageString.append("""
				],
				targets: [
			
			""")
		packageString.append(types.map{ type in
			let checksum = checksums[type]!
			if let checksum = checksum {
				/* TODO: Customize URL */
				return #"\#t\#t.binaryTarget(name: "\#(buildPaths.productName)-\#(type)", url: "https://github.com/xcode-actions/\#(buildPaths.productName)/releases/download/\#(BuiltTarget.normalizedOpenSSLVersion(version!))/\#(buildPaths.productName)-\#(type).xcframework.zip", checksum: "\#(checksum)")"#
			} else {
				return #"\#t\#t.binaryTarget(name: "\#(buildPaths.productName)-\#(type)", path: "./\#(buildPaths.productName)-\#(type).xcframework")"#
			}
		}.joined(separator: ",\n") + "\n")
		packageString.append("""
				]
			)
			
			""")
		return packageString
	}
	
}
