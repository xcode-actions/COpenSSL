import Foundation



struct UnbuiltDynamicXCFramework {
	
	var frameworks: [FilePath]
	
	var skipExistingArtifacts: Bool
	
	func buildXCFramework(at destPath: FilePath) throws {
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
		
		try Process.spawnAndStreamEnsuringSuccess(
			"/usr/bin/xcrun",
			args: ["xcodebuild", "-create-xcframework"] + frameworks.flatMap{ ["-framework", $0.string] } + ["-output", destPath.string],
			outputHandler: Process.logProcessOutputFactory()
		)
	}
	
}
