import Foundation

import XcodeTools



struct UnbuiltFATLib {
	
	var libs: [FilePath]
	var skipExistingArtifacts: Bool
	
	func buildFATLib(at destPath: FilePath) async throws {
		guard libs.count > 0 else {
			Config.logger.warning("Asked to create a FAT lib at path \(destPath), but no libs given.")
			return
		}
		guard !skipExistingArtifacts || !Config.fm.fileExists(atPath: destPath.string) else {
			Config.logger.info("Skipping creation of \(destPath) because it already exists")
			return
		}
		try Config.fm.ensureDirectory(path: destPath.removingLastComponent())
		try Config.fm.ensureFileDeleted(path: destPath)
		
		Config.logger.info("Creating FAT lib \(destPath) from \(libs.count) lib(s)")
		try await ProcessInvocation("lipo", args: ["-create"] + libs.map{ $0.string } + ["-output", destPath.string])
			.invokeAndStreamOutput{ line, _, _ in Config.logger.info("lipo: fd=\(line.fd): \(line.strLineOrHex())") }
	}
	
}
