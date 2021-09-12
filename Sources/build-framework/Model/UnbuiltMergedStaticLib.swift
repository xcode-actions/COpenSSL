import Foundation

import XcodeTools



struct UnbuiltMergedStaticLib {
	
	var libs: [FilePath]
	var skipExistingArtifacts: Bool
	
	func buildMergedLib(at destPath: FilePath) async throws {
		guard libs.count > 0 else {
			Config.logger.warning("Asked to create a merged static lib at path \(destPath), but no libs given.")
			return
		}
		guard !skipExistingArtifacts || !Config.fm.fileExists(atPath: destPath.string) else {
			Config.logger.info("Skipping creation of \(destPath) because it already exists")
			return
		}
		try Config.fm.ensureDirectory(path: destPath.removingLastComponent())
		try Config.fm.ensureFileDeleted(path: destPath)
		
		Config.logger.info("Merging \(libs.count) lib(s) to \(destPath)")
		try await ProcessInvocation("/usr/bin/xcrun", args: ["libtool", "-static", "-o", destPath.string] + libs.map{ $0.string })
			.invokeAndStreamOutput{ line, _, _ in Config.logger.debug("libtool: fd=\(line.fd.rawValue): \(line.strLineOrHex())") }
	}
	
}
