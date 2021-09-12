import Foundation

import XcodeTools



struct UnbuiltDynamicXCFramework {
	
	var frameworks: [FilePath]
	
	var skipExistingArtifacts: Bool
	
	func buildXCFramework(at destPath: FilePath) async throws {
		guard frameworks.count > 0 else {
			Config.logger.warning("Asked to create an XCFramework at path \(destPath), but no frameworks given.")
			return
		}
		guard !skipExistingArtifacts || !Config.fm.fileExists(atPath: destPath.string) else {
			Config.logger.info("Skipping creation of \(destPath) because it already exists")
			return
		}
		try Config.fm.ensureDirectory(path: destPath.removingLastComponent())
		try Config.fm.ensureDirectoryDeleted(path: destPath)
		
		try await ProcessInvocation("xcodebuild", args: ["-create-xcframework"] + frameworks.flatMap{ ["-framework", $0.string] } + ["-output", destPath.string])
			.invokeAndStreamOutput{ line, _, _ in Config.logger.debug("xcodebuild: fd=\(line.fd.rawValue): \(line.strLineOrHex())") }
	}
	
}
