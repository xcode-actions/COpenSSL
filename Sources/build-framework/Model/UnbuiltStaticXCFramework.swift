import Foundation

import XcodeTools



struct UnbuiltStaticXCFramework {
	
	var librariesAndHeadersDir: [(library: FilePath, headersDir: FilePath)]
	
	var skipExistingArtifacts: Bool
	
	func buildXCFramework(at destPath: FilePath) async throws {
		guard librariesAndHeadersDir.count > 0 else {
			Config.logger.warning("Asked to create an XCFramework at path \(destPath), but no library and headers dir given.")
			return
		}
		guard !skipExistingArtifacts || !Config.fm.fileExists(atPath: destPath.string) else {
			Config.logger.info("Skipping creation of \(destPath) because it already exists")
			return
		}
		try Config.fm.ensureDirectory(path: destPath.removingLastComponent())
		try Config.fm.ensureDirectoryDeleted(path: destPath)
		
		try await ProcessInvocation("xcodebuild", args: ["-create-xcframework"] + librariesAndHeadersDir.flatMap{ ["-library", $0.library.string, "-headers", $0.headersDir.string] } + ["-output", destPath.string])
			.invokeAndStreamOutput{ line, _, _ in Config.logger.info("xcodebuild: fd=\(line.fd): \(line.strLineOrHex())") }
	}
	
}
