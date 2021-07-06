import Foundation
import System

import Logging



/** All the paths relevant to the build */
@available(macOS 12.0, *) // TODO: Remove when v12 exists in Package.swift
struct BuildPaths {
	
	/** Not really a path, but hella convenient to have here */
	let productName: String
	
	let resultXCFrameworkStatic: FilePath
	let resultXCFrameworkDynamic: FilePath
	
	let developerDir: FilePath
	
	let opensslConfigsDir: FilePath
	let templatesDir: FilePath
	
	let workDir: FilePath
	let resultDir: FilePath
	let buildDir: FilePath
	
	/** Contains the extracted tarball, config’d and built. One dir per target. */
	let sourcesDir: FilePath
	/** The builds from the previous step are installed here. */
	let installsDir: FilePath
	/** The static libs must be made FAT. We put the FAT ones here. */
	let fatStaticDir: FilePath
	/** This contains extracted static libs, linked later to create the dylibs. */
	let libObjectsDir: FilePath
	/** The dylibs created from the `libObjectsDir`. */
	let dylibsDir: FilePath
	/** Contains the libs from previous step, but merged as one.
	 
	 We have to do this because xcodebuild does not do it automatically when
	 building an xcframework (this is understandable) and xcframeworks do not
	 support multiple libs. */
	let mergedFatStaticLibsDir: FilePath
	/** Contains the libs from previous step, one per platform+sdk instead of one
	 per target (marged as FAT).
	 
	 We have to do this because xcodebuild does not do it automatically when
	 building an xcframework (this is understandable), and an xcframework
	 splits the underlying framework on platform+sdk, not platform+sdk+arch.
	 
	 - Note: For symetry with its static counterpart we name this variable
	 `mergedFatDynamicLibsDir`, but the dynamic libs are merged from the
	 extracted static libs directly into one lib, so the `merged` part of the
	 variable is not strictly relevant. */
	let mergedFatDynamicLibsDir: FilePath
	
	/** Contains theh final frameworks from which the dynamic xcframework will be
	 built. */
	let finalFrameworksDir: FilePath
	/** Contains the final full static lib install (with headers) from which
	 the static xcframework will be built. */
	let finalStaticLibsAndHeadersDir: FilePath
	
	init(filesPath: FilePath, workdir: FilePath, resultdir: FilePath?, productName: String) throws {
		self.developerDir = try FilePath(
			Process.spawnAndGetOutput("/usr/bin/xcode-select", args: ["-print-path"]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
		)
		
		self.opensslConfigsDir = filesPath.appending("OpenSSLConfigs")
		self.templatesDir = filesPath.appending("Templates")
		
		self.workDir = workdir
		self.resultDir = resultdir ?? workdir
		self.buildDir = self.workDir.appending("build")
		
		/* Actual (full) validation would be a bit more complex than that */
		let productNameValid = (productName.first(where: { !$0.isASCII || (!$0.isLetter && !$0.isNumber && $0 != "_") }) == nil)
		guard
			productNameValid,
			let  staticXCFrameworkComponent = FilePath.Component(productName +  "-static.xcframework"),  staticXCFrameworkComponent.kind == .regular,
			let dynamicXCFrameworkComponent = FilePath.Component(productName + "-dynamic.xcframework"), dynamicXCFrameworkComponent.kind == .regular
		else {
			struct InvalidProductName : Error {var productName: String}
			throw InvalidProductName(productName: productName)
		}
		
		self.productName = productName
		self.resultXCFrameworkStatic  = self.resultDir.appending(staticXCFrameworkComponent)
		self.resultXCFrameworkDynamic = self.resultDir.appending(dynamicXCFrameworkComponent)
		
		self.sourcesDir  = self.buildDir.appending("step1.sources-and-builds")
		self.installsDir = self.buildDir.appending("step2.installs")
		
		self.fatStaticDir  = self.buildDir.appending("step3.lib-derivatives/fat-static-libs")
		self.libObjectsDir = self.buildDir.appending("step3.lib-derivatives/lib-objects")
		self.dylibsDir     = self.buildDir.appending("step3.lib-derivatives/merged-dynamic-libs")
		
		self.mergedFatStaticLibsDir  = self.buildDir.appending("step4.merged-fat-libs/static")
		self.mergedFatDynamicLibsDir = self.buildDir.appending("step4.merged-fat-libs/dynamic")
		
		self.finalFrameworksDir           = self.buildDir.appending("step5.final-frameworks-and-libs/frameworks")
		self.finalStaticLibsAndHeadersDir = self.buildDir.appending("step5.final-frameworks-and-libs/static-libs-and-headers")
	}
	
	func clean() throws {
		try Config.fm.ensureDirectoryDeleted(path: buildDir)
		try Config.fm.ensureDirectoryDeleted(path: resultXCFrameworkStatic)
		try Config.fm.ensureDirectoryDeleted(path: resultXCFrameworkDynamic)
	}
	
	func ensureAllDirectoriesExist() throws {
		try Config.fm.ensureDirectory(path: workDir)
		try Config.fm.ensureDirectory(path: resultDir)
		try Config.fm.ensureDirectory(path: buildDir)
		
		try Config.fm.ensureDirectory(path: sourcesDir)
		try Config.fm.ensureDirectory(path: installsDir)
		try Config.fm.ensureDirectory(path: fatStaticDir)
		try Config.fm.ensureDirectory(path: libObjectsDir)
		try Config.fm.ensureDirectory(path: dylibsDir)
		
		try Config.fm.ensureDirectory(path: mergedFatStaticLibsDir)
		try Config.fm.ensureDirectory(path: mergedFatDynamicLibsDir)
		
		try Config.fm.ensureDirectory(path: finalFrameworksDir)
		try Config.fm.ensureDirectory(path: finalStaticLibsAndHeadersDir)
	}
	
	func sourceDir(for target: Target) -> FilePath {
		return sourcesDir.appending(target.pathComponent)
	}
	
	func installDir(for target: Target) -> FilePath {
		return installsDir.appending(target.pathComponent)
	}
	
	func libObjectsDir(for target: Target) -> FilePath {
		return libObjectsDir.appending(target.pathComponent)
	}
	
	func dylibsDir(for target: Target) -> FilePath {
		return dylibsDir.appending(target.pathComponent)
	}
	
	func opensslConfigsDir(for version: String) throws -> FilePath {
		var currentVersion = version
		while true {
			guard let component = FilePath.Component(currentVersion) else {
				struct CannotGetFilePathComponentFromVersion : Error {var version: String}
				throw CannotGetFilePathComponentFromVersion(version: version)
			}
			
			let path = opensslConfigsDir.appending(component)
			
			var isDir = ObjCBool(false)
			if Config.fm.fileExists(atPath: path.string, isDirectory: &isDir) {
				guard isDir.boolValue else {
					struct ConfigDirIsAFile : Error {var path: FilePath}
					throw ConfigDirIsAFile(path: path)
				}
				return path
			} else {
				/* The config dir does not exist for this exact version. Let’s see
				 * if we can find a config for a less specific version. */
				if component.extension?.contains("-") ?? true {
					/* Either the current version does not have an extension (e.g. 1)
					 * or the current extension has a dash. If we have a dash we drop
					 * everything after it including it and try again. */
					if let idx = component.string.lastIndex(of: "-") {
						currentVersion = String(component.string[component.string.startIndex..<idx])
					} else {
						struct ConfigDirNotFoundForVersion : Error {var version: String}
						throw ConfigDirNotFoundForVersion(version: version)
					}
				} else if let ext = component.extension, ext.lastIndex(where: { $0.isLetter }) == ext.index(before: ext.endIndex) {
					currentVersion = String(currentVersion.dropLast())
				} else {
					/* The current version has an “extension” that does not contain a
					 * dash. We drop it and retry. */
					currentVersion = component.stem
				}
			}
		}
	}
	
}
