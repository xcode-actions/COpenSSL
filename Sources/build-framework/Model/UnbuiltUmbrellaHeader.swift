import Foundation



@available(macOS 12.0, *) // TODO: Remove when v12 exists in Package.swift
struct UnbuiltUmbrellaHeader {
	
	var headers: [FilePath]
	var productName: String
	
	var skipExistingArtifacts: Bool
	
	func buildUmbrellaHeader(at destPath: FilePath) throws {
		guard headers.count > 0 else {
			Config.logger.warning("Asked to create an umbrella header at path \(destPath), but no headers given.")
			return
		}
		guard !skipExistingArtifacts || !Config.fm.fileExists(atPath: destPath.string) else {
			Config.logger.info("Skipping creation of \(destPath) because it already exists")
			return
		}
		try Config.fm.ensureDirectory(path: destPath.removingLastComponent())
		try Config.fm.ensureFileDeleted(path: destPath)
		
		Config.logger.info("Creating umbrella header \(destPath) from \(headers.count) header(s)")
		var contents = "/* Umbrella header for \(productName) */\n\n"
		for header in headers {
			contents += "#include <\(productName)/\(header.string)>\n"
		}
		try contents.write(to: destPath.url, atomically: false, encoding: .utf8)
	}
	
}
