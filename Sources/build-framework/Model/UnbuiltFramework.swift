import Foundation
import System



@available(macOS 12.0, *) // TODO: Remove when v12 exists in Package.swift
struct UnbuiltFramework {
	
	/** Should be `nil` for non-macOS frameworks, otherwise should probably be A. */
	var version: String?
	
	var libPath: FilePath
	var headers: [FilePath]
	var modules: [FilePath]
	/** The framework resources, except for the Info.plist */
	var resources: [FilePath]
	
	var pathsRoot: FilePath
	
	var skipExistingArtifacts: Bool
	
	func buildFramework(at destPath: FilePath) throws {
		guard !skipExistingArtifacts || !Config.fm.fileExists(atPath: destPath.string) else {
			Config.logger.info("Skipping creation of \(destPath) because it already exists")
			return
		}
		try Config.fm.ensureDirectoryDeleted(path: destPath)
		try Config.fm.ensureDirectory(path: destPath)
		
		guard let frameworkPathComponent = destPath.lastComponent, let binaryPathComponent = FilePath.Component(frameworkPathComponent.stem) else {
			struct InvalidDestination : Error {var destination: FilePath}
			throw InvalidDestination(destination: destPath)
		}
		let headersPathComponent = FilePath.Component("Headers")
		let modulesPathComponent = FilePath.Component("Modules")
		let resourcesPathComponent = FilePath.Component("Resources")
		let infoplistPathComponents = (version != nil ? [resourcesPathComponent] : []) + [FilePath.Component("Info.plist")]
		
		let workDir: FilePath
		if let v = version {
			guard let versionComponent = FilePath.Component(v) else {
				struct InvalidVersion : Error {var version: String}
				throw InvalidVersion(version: v)
			}
//			let relativeVersionPath = FilePath("Versions").appending(versionComponent)
			/* We MUST use a temporary variable here instead of
			 * `workDir = destPath.appending(relativeVersionPath)` directly or we
			 * get a crash (double-free). Got this on macOS 12 beta 2 21A5268h,
			 * Xcode 13 beta 2 13A5155e. */
			let tmp = destPath.appending("Versions")
			workDir = tmp.appending(versionComponent)
			try Config.fm.ensureDirectory(path: workDir)
			
			/* Create links to folders if needed */
			let relativeCurrentPath = FilePath("Versions/Current")
			if !headers.isEmpty {try Config.fm.createSymbolicLink(atPath: destPath.appending(headersPathComponent).string, withDestinationPath: relativeCurrentPath.appending(headersPathComponent).string)}
			if !modules.isEmpty {try Config.fm.createSymbolicLink(atPath: destPath.appending(modulesPathComponent).string, withDestinationPath: relativeCurrentPath.appending(modulesPathComponent).string)}
			try Config.fm.createSymbolicLink(atPath: destPath.appending(resourcesPathComponent).string, withDestinationPath: relativeCurrentPath.appending(resourcesPathComponent).string)
			try Config.fm.createSymbolicLink(atPath: destPath.appending(binaryPathComponent).string, withDestinationPath: relativeCurrentPath.appending(binaryPathComponent).string)
			try Config.fm.createSymbolicLink(atPath: destPath.appending("Versions/Current").string, withDestinationPath: versionComponent.string)
		} else {
			workDir = destPath
		}
		
		let headersPath = workDir.appending(headersPathComponent)
		let modulesPath = workDir.appending(modulesPathComponent)
		let resourcesPath = workDir.appending(resourcesPathComponent)
		let infoplistPath = workDir.appending(infoplistPathComponents)
		let installedLibPath = workDir.appending(binaryPathComponent)
		
		/* Create folders if needed */
		if !headers.isEmpty {try Config.fm.ensureDirectory(path: headersPath)}
		if !modules.isEmpty {try Config.fm.ensureDirectory(path: modulesPath)}
		if !resources.isEmpty || version != nil {try Config.fm.ensureDirectory(path: resourcesPath)}
		
		/* Copy the binary */
		try Config.fm.copyItem(at: pathsRoot.pushing(libPath).url, to: installedLibPath.url)
		/* Renaming the lib */
		Config.logger.info("Updating install name of dylib at \(installedLibPath)")
		try Process.spawnAndStreamEnsuringSuccess(
			"/usr/bin/xcrun",
			args: ["install_name_tool", "-id", "@rpath/\(frameworkPathComponent.string)/\(binaryPathComponent.string)", installedLibPath.string],
			outputHandler: Process.logProcessOutputFactory()
		)
		
		for header in headers {
			guard header.root == nil else {
				struct InvalidNonRelativeHeader : Error {var headerPath: FilePath}
				throw InvalidNonRelativeHeader(headerPath: header)
			}
			let headerNoInclude: FilePath
			if !header.starts(with: "include") {
				Config.logger.warning("Got header not in the “include” directory, which is unexpected. Copying into the Framework without dropping first path component.")
				headerNoInclude = header
			} else {
				/* The proper way to do this is the commented line below. However,
				 * it currently crashes (Xcode 13A5155e, macOS 21A5268h) */
//				headerNoInclude = FilePath(root: nil, header.components.dropFirst())
				headerNoInclude = FilePath(String(header.string.dropFirst("include/".count)))
			}
			try Config.fm.ensureDirectory(path: headersPath.pushing(headerNoInclude).removingLastComponent())
			try Config.fm.copyItem(at: pathsRoot.pushing(header).url, to: headersPath.pushing(headerNoInclude).url)
		}
	}
	
}
