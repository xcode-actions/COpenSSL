import Foundation
import System

import Logging
import XcodeTools



/** All the paths relevant to the build */
struct BuildPaths {
	
	/** Not really a path, but hella convenient to have here */
	let productName: String
	let dylibProductNameComponent: FilePath.Component
	let staticLibProductNameComponent: FilePath.Component
	let frameworkProductNameComponent: FilePath.Component
	
	let resultXCFrameworkStatic: FilePath
	let resultXCFrameworkDynamic: FilePath
	
	let resultPackageSwift: FilePath
	let resultXCFrameworkStaticArchive: FilePath
	let resultXCFrameworkDynamicArchive: FilePath
	
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
	/** Contains the headers from Target merged into platform+sdk tuple for the
	 static framework.
	 
	 Sometimes the headers are not exactly the same between architectures, so we
	 have to merge them in order to get the correct headers all the time. Also
	 the headers have to be patched to be able to be used in an XCFramework. */
	let mergedStaticHeadersDir: FilePath
	/**
	 Contains the libs from previous step, but merged as one.
	 
	 We have to do this because xcodebuild does not do it automatically when
	 building an xcframework (this is understandable) and xcframeworks do not
	 support multiple libs. */
	let mergedFatStaticLibsDir: FilePath
	/** Contains the headers from Target merged into platform+sdk tuple for the
	 dynamic framework.
	 
	 Sometimes the headers are not exactly the same between architectures, so we
	 have to merge them in order to get the correct headers all the time. Also
	 the headers have to be patched to be able to be used in a Framework. */
	let mergedDynamicHeadersDir: FilePath
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
	
	/** Contains the final frameworks from which the dynamic xcframework will be
	 built. */
	let finalFrameworksDir: FilePath
	/** Contains the final full static lib install (with headers) from which
	 the static xcframework will be built. */
	let finalStaticLibsAndHeadersDir: FilePath
	
	init(filesPath: FilePath, workdir: FilePath, resultdir: FilePath?, productName: String) async throws {
		struct NotExactlyOneLineFromXcodeSelect : Error {}
		self.developerDir = try await FilePath(
			ProcessInvocation("/usr/bin/xcode-select", "-print-path").invokeAndGetStdout().onlyElement.get(orThrow: NotExactlyOneLineFromXcodeSelect())
		)
		
		self.opensslConfigsDir = filesPath.appending("OpenSSLConfigs")
		self.templatesDir = filesPath.appending("Templates")
		
		self.workDir = System.FilePath(FileManager.default.currentDirectoryPath).pushing(workdir)
		self.resultDir = System.FilePath(FileManager.default.currentDirectoryPath).pushing(resultdir ?? workdir)
		self.buildDir = self.workDir.appending("build")
		
		/* Actual (full) validation would be a bit more complex than that */
		let productNameValid = (productName.first(where: { !$0.isASCII || (!$0.isLetter && !$0.isNumber && $0 != "_") }) == nil)
		guard
			productNameValid,
			let dylibProductNameComponent     = FilePath.Component("lib" + productName +         ".dylib"),           dylibProductNameComponent.kind == .regular,
			let staticLibProductNameComponent = FilePath.Component("lib" + productName +         ".a"),           staticLibProductNameComponent.kind == .regular,
			let frameworkProductNameComponent = FilePath.Component(        productName +         ".framework"),   frameworkProductNameComponent.kind == .regular,
			let staticXCFrameworkComponent    = FilePath.Component(        productName +  "-static.xcframework"),    staticXCFrameworkComponent.kind == .regular,
			let dynamicXCFrameworkComponent   = FilePath.Component(        productName + "-dynamic.xcframework"),   dynamicXCFrameworkComponent.kind == .regular
		else {
			struct InvalidProductName : Error {var productName: String}
			throw InvalidProductName(productName: productName)
		}
		
		self.productName = productName
		self.dylibProductNameComponent = dylibProductNameComponent
		self.staticLibProductNameComponent = staticLibProductNameComponent
		self.frameworkProductNameComponent = frameworkProductNameComponent
		self.resultXCFrameworkStatic  = self.resultDir.appending(staticXCFrameworkComponent)
		self.resultXCFrameworkDynamic = self.resultDir.appending(dynamicXCFrameworkComponent)
		
		self.resultPackageSwift = self.resultDir.appending("Package.swift")
		self.resultXCFrameworkStaticArchive  = self.resultDir.appending( staticXCFrameworkComponent.string + ".zip")
		self.resultXCFrameworkDynamicArchive = self.resultDir.appending(dynamicXCFrameworkComponent.string + ".zip")
		
		self.sourcesDir  = self.buildDir.appending("step1.sources-and-builds")
		self.installsDir = self.buildDir.appending("step2.installs")
		
		self.fatStaticDir  = self.buildDir.appending("step3.intermediate-derivatives/fat-static-libs")
		self.libObjectsDir = self.buildDir.appending("step3.intermediate-derivatives/lib-objects")
		self.dylibsDir     = self.buildDir.appending("step3.intermediate-derivatives/dylibs")
		
		self.mergedStaticHeadersDir  = self.buildDir.appending("step4.final-derivatives/static-headers")
		self.mergedDynamicHeadersDir = self.buildDir.appending("step4.final-derivatives/dynamic-headers")
		self.mergedFatStaticLibsDir  = self.buildDir.appending("step4.final-derivatives/static-libs")
		self.mergedFatDynamicLibsDir = self.buildDir.appending("step4.final-derivatives/dynamic-libs")
		
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
		
		try Config.fm.ensureDirectory(path: mergedStaticHeadersDir)
		try Config.fm.ensureDirectory(path: mergedFatStaticLibsDir)
		try Config.fm.ensureDirectory(path: mergedDynamicHeadersDir)
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
				} else if let ext = component.extension, ext.last?.isLetter ?? false {
					/* The current version has an “extension” whose last character is
					 * a letter (e.g. “1.1.1k”). We drop the letter and try again. */
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
