import Foundation
import System

import XibLoc
import SystemPackage
import XcodeTools



struct UnbuiltFramework {
	
	struct Info {
		
		var platform: String
		
		var developmentRegion = "en"
		var executable: String
		var identifier: String
		var name: String
		var marketingVersion: String
		var buildVersion: String
		var minimumOSVersion: String
		
		var plistDictionary: [String: Any] {
			let minimumOSVersionKey = (platform == "macOS" ? "LSMinimumSystemVersion" : "MinimumOSVersion")
			return [
				"CFBundleInfoDictionaryVersion": "6.0",
				"CFBundlePackageType": "FMWK",
				"CFBundleDevelopmentRegion": developmentRegion,
				
				"CFBundleExecutable": executable,
				"CFBundleIdentifier": identifier,
				"CFBundleName": name,
				
				"CFBundleShortVersionString": marketingVersion,
				"CFBundleVersion": buildVersion,
				minimumOSVersionKey: minimumOSVersion,
				
				"CFBundleSupportedPlatforms": [Target.platformLegacyName(fromPlatform: platform)]
			]
		}
		
		var plistData: Data {
			get throws {
				return try PropertyListSerialization.data(fromPropertyList: plistDictionary, format: .xml, options: 0)
			}
		}
		
	}
	
	/** Should be `nil` for non-macOS frameworks, otherwise should probably be A. */
	var version: String?
	
	var info: Info
	
	var libPath: FilePath
	var headers: [(root: FilePath, file: FilePath)]
	var modules: [(root: FilePath, file: FilePath)]
	/** The framework resources, except for the Info.plist */
	var resources: [(root: FilePath, file: FilePath)]
	
	var skipExistingArtifacts: Bool
	
	func buildFramework(at destPath: FilePath) async throws {
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
		
		let moduleName = binaryPathComponent.string
		
		let headersPath = workDir.appending(headersPathComponent)
		let modulesPath = workDir.appending(modulesPathComponent)
		let resourcesPath = workDir.appending(resourcesPathComponent)
		let infoplistPath = workDir.appending(infoplistPathComponents)
		let installedLibPath = workDir.appending(binaryPathComponent)
		
		/* Copy the binary */
		try Config.fm.copyItem(at: libPath.url, to: installedLibPath.url)
		/* Renaming the lib */
		Config.logger.info("Updating install name of dylib at \(installedLibPath)")
		try await ProcessInvocation("/usr/bin/xcrun", "install_name_tool", "-id", "@rpath/\(frameworkPathComponent.string)/\(binaryPathComponent.string)", installedLibPath.string)
			.invokeAndStreamOutput{ line, _, _ in Config.logger.info("install_name_tool: fd=\(line.fd): \(line.strLineOrHex())") }
		
		/* Create the Info.plist */
		try Config.fm.ensureDirectory(path: infoplistPath.removingLastComponent())
		try info.plistData.write(to: infoplistPath.url)
		
		try installFiles(headers,   installDest: headersPath,   moduleName: moduleName)
		try installFiles(resources, installDest: resourcesPath, moduleName: moduleName)
		
		for module in modules {
			/* TODO: Commented check crashes currently in Xcode/macOS beta 2 */
			guard module.file.root == nil/*, module.file.components.count == 1*/ else {
				struct InvalidModulePath : Error {var path: FilePath}
				throw InvalidModulePath(path: module.file)
			}
			try installFileDetemplating(module.root.pushing(module.file), to: modulesPath.pushing(module.file), moduleName: moduleName)
		}
	}
	
	private func installFiles(_ files: [(root: FilePath, file: FilePath)], installDest: FilePath, moduleName: String) throws {
		for file in files {
			guard file.file.root == nil else {
				struct InvalidNonRelativeHeader : Error {var path: FilePath}
				throw InvalidNonRelativeHeader(path: file.file)
			}
			try installFileDetemplating(file.root.pushing(file.file), to: installDest.pushing(file.file), moduleName: moduleName)
		}
	}
	
	private func installFileDetemplating(_ source: FilePath, to dest: FilePath, moduleName: String) throws {
		try Config.fm.ensureDirectory(path: dest.removingLastComponent())
		if source.extension == "xibloc", let stem = source.stem {
			let filecontent = try String(contentsOf: source.url)
			try filecontent.applying(xibLocInfo: Str2StrXibLocInfo(replacements: ["|": moduleName])!)
				.write(to: dest.removingLastComponent().appending(stem).url, atomically: false, encoding: .utf8)
		} else {
			try Config.fm.copyItem(at: source.url, to: dest.url)
		}
	}
	
}
