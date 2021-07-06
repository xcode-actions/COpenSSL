import Foundation



@available(macOS 12.0, *) // TODO: Remove when v12 exists in Package.swift
struct UnbuiltFATLib {
	
	var libs: [FilePath]
	var skipExistingArtifacts: Bool
	
	func buildFATLib(at destPath: FilePath) throws {
		guard !skipExistingArtifacts || !Config.fm.fileExists(atPath: destPath.string) else {
			Config.logger.info("Skipping creation of \(destPath) because it already exists")
			return
		}
		try Config.fm.ensureDirectory(path: destPath.removingLastComponent())
		try Config.fm.ensureFileDeleted(path: destPath)
		
		Config.logger.info("Creating FAT lib \(destPath) from \(libs.count) lib(s)")
		try Process.spawnAndStreamEnsuringSuccess(
			"/usr/bin/xcrun",
			args: ["lipo", "-create"] + libs.map{ $0.string } + ["-output", destPath.string],
			outputHandler: Process.logProcessOutputFactory()
		)
	}
	
}
