import Foundation
import System



@available(macOS 12.0, *) // TODO: Remove when v12 exists in Package.swift
struct UnbuiltFramework {
	
	var libPath: FilePath
	var headers: [FilePath]
	var modules: [FilePath]
	/** The framework resources, except for the Info.plist */
	var resources: [FilePath]
	
	var skipExistingArtifacts: Bool
	
	func buildFramework(at destPath: FilePath) throws {
		guard !skipExistingArtifacts || !Config.fm.fileExists(atPath: destPath.string) else {
			Config.logger.info("Skipping creation of \(destPath) because it already exists")
			return
		}
		try Config.fm.ensureDirectoryDeleted(path: destPath)
		try Config.fm.ensureDirectory(path: destPath)
		// TODO
	}
	
}
