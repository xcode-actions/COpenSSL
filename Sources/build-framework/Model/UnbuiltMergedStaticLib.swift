import Foundation



@available(macOS 12.0, *) // TODO: Remove when v12 exists in Package.swift
struct UnbuiltMergedStaticLib {
	
	var libs: [FilePath]
	var skipExistingArtifacts: Bool
	
	func buildMergedLib(at destPath: FilePath) throws {
		guard !skipExistingArtifacts || !Config.fm.fileExists(atPath: destPath.string) else {
			Config.logger.info("Skipping creation of \(destPath) because it already exists")
			return
		}
		try Config.fm.ensureDirectory(path: destPath.removingLastComponent())
		try Config.fm.ensureFileDeleted(path: destPath)
		
		Config.logger.info("Merging \(libs.count) lib(s) to \(destPath)")
		try Process.spawnAndStreamEnsuringSuccess(
			"/usr/bin/xcrun",
			args: ["libtool", "-static", "-o", destPath.string] + libs.map{ $0.string },
			outputHandler: Process.logProcessOutputFactory()
		)
	}
	
}
