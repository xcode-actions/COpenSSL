import Foundation
import System

import ArgumentParser
import CLTLogger
import Logging
import XcodeTools



@main
@available(macOS 12.0, *) // TODO: Remove when v12 exists in Package.swift
struct BuildFramework : ParsableCommand {
	
	@Option(help: "The path to the “Files” directory, containing some resources to build OpenSSL.")
	var filesPath = Self.defaultFilesFolderURL.path
	
	@Option(help: "Everything build-framework will create will be in this folder, except the final xcframeworks. The folder will be created if it does not exist.")
	var workdir = "./openssl-workdir"
	
	@Option(help: "The final xcframeworks will be in this folder. If unset, will be equal to the work dir. The folder will be created if it does not exist.")
	var resultdir: String?
	
	@Option(help: "The base URL from which to download OpenSSL. Everything between double curly braces “{{}}” will be replaced by the OpenSSL version to build.")
	var opensslBaseURL = "https://www.openssl.org/source/openssl-{{ version }}.tar.gz"
	
	@Option
	var opensslVersion = "1.1.1k"
	
	/* For 1.1.1k, value is 892a0875b9872acd04a9fde79b1f943075d5ea162415de3047c327df33fbaee5 */
	@Option(help: "The shasum-256 expected for the tarball. If not set, the integrity of the archive will not be verified.")
	var expectedTarballShasum: String?
	
	@Flag
	var disableBitcode = false
	
	@Flag
	var clean = false
	
	@Flag
	var skipExistingArtifacts = false
	
	@Option
	var targets = [
		Target(sdk: "macOS", platform: "macOS", arch: "arm64"),
		Target(sdk: "macOS", platform: "macOS", arch: "x86_64"),
		
		Target(sdk: "iOS", platform: "iOS", arch: "arm64"),
		Target(sdk: "iOS", platform: "iOS", arch: "arm64e"),
		
		Target(sdk: "iOS", platform: "iOS_Simulator", arch: "arm64"),
		Target(sdk: "iOS", platform: "iOS_Simulator", arch: "x86_64"),
		
		Target(sdk: "iOS", platform: "macOS", arch: "arm64"),
		Target(sdk: "iOS", platform: "macOS", arch: "x86_64"),
		
		Target(sdk: "tvOS", platform: "tvOS", arch: "arm64"),
		
//		Target(sdk: "tvOS", platform: "tvOS_Simulator", arch: "arm64"), /* Was not in original build repo, but why not add it one of these days if it exists */
		Target(sdk: "tvOS", platform: "tvOS_Simulator", arch: "x86_64"),
		
		Target(sdk: "watchOS", platform: "watchOS", arch: "armv7k"),
		Target(sdk: "watchOS", platform: "watchOS", arch: "arm64_32"),
		
		Target(sdk: "watchOS", platform: "watchOS_Simulator", arch: "arm64"),
		Target(sdk: "watchOS", platform: "watchOS_Simulator", arch: "x86_64"),
		Target(sdk: "watchOS", platform: "watchOS_Simulator", arch: "i386")
	]
	
	@Option(name: .customLong("macos-sdk-version"))
	var macOSSDKVersion: String?
	
	@Option(name: .customLong("macos-min-sdk-version"))
	var macOSMinSDKVersion: String?
	
	@Option(name: .customLong("ios-sdk-version"))
	var iOSSDKVersion: String?
	
	@Option(name: .customLong("ios-min-sdk-version"))
	var iOSMinSDKVersion: String?
	
	@Option
	var catalystSDKVersion: String?
	
	@Option
	var catalystMinSDKVersion: String?
	
	@Option(name: .customLong("watchos-sdk-version"))
	var watchOSSDKVersion: String?
	
	@Option(name: .customLong("watchos-min-sdk-version"))
	var watchOSMinSDKVersion: String?
	
	@Option(name: .customLong("tvos-sdk-version"))
	var tvOSSDKVersion: String?
	
	@Option(name: .customLong("tvos-min-sdk-version"))
	var tvOSMinSDKVersion: String?
	
	func run() async throws {
		LoggingSystem.bootstrap{ _ in CLTLogger() }
		XcodeTools.XcodeToolsConfig.logger?.logLevel = .warning
		let logger = { () -> Logger in
			var ret = Logger(label: "me.frizlab.build-openssl")
			ret.logLevel = .debug
			return ret
		}()
		
		let fm = FileManager.default
		let buildPaths = try BuildPaths(filesPath: FilePath(filesPath), workdir: FilePath(workdir), resultdir: resultdir.flatMap{ FilePath($0) }, productName: "COpenSSL")
		
		if clean {
			logger.info("Cleaning previous builds if applicable")
			try buildPaths.clean(fileManager: fm)
		}
		try buildPaths.ensureAllDirectoriesExist(fileManager: fm)
		
		let tarball = try Tarball(templateURL: opensslBaseURL, version: opensslVersion, downloadFolder: buildPaths.workDir, expectedShasum: expectedTarballShasum, logger: logger)
		try await tarball.ensureDownloaded(fileManager: fm, logger: logger)
		
		/* Build all the variants we need. Note only static libs are built because
		 * we merge them later in a single dyn lib to create a single framework. */
		var dylibs = [Target: FilePath]()
		var builtTargets = [Target: BuiltTarget]()
		for target in targets {
			let sdkVersion: String?
			let minSDKVersion: String?
			switch target.platform {
				case   "macOS": (sdkVersion, minSDKVersion) = (  macOSSDKVersion,   macOSMinSDKVersion)
				case     "iOS": (sdkVersion, minSDKVersion) = (    iOSSDKVersion,     iOSMinSDKVersion)
				case    "tvOS": (sdkVersion, minSDKVersion) = (   tvOSSDKVersion,    tvOSMinSDKVersion)
				case "watchOS": (sdkVersion, minSDKVersion) = (watchOSSDKVersion, watchOSMinSDKVersion)
				default:        (sdkVersion, minSDKVersion) = (nil, nil)
			}
			let unbuiltTarget = UnbuiltTarget(target: target, tarball: tarball, buildPaths: buildPaths, sdkVersion: sdkVersion, minSDKVersion: minSDKVersion, opensslVersion: opensslVersion, disableBitcode: disableBitcode, skipExistingArtifacts: skipExistingArtifacts)
			let builtTarget = try unbuiltTarget.buildTarget(fileManager: fm, logger: logger)
			
			assert(builtTargets[target] == nil)
			builtTargets[target] = builtTarget
			
			assert(dylibs[target] == nil)
			dylibs[target] = try builtTarget.buildDylibFromStaticLibs(opensslVersion: opensslVersion, buildPaths: buildPaths, skipExistingArtifacts: skipExistingArtifacts, fileManager: fm, logger: logger)
		}
		
		let targetsByPlatformAndSdks = Dictionary(grouping: targets, by: { PlatformAndSdk(platform: $0.platform, sdk: $0.sdk) })
		
		/* Create all the frameworks and related needed to create the final static
		 * and dynamic xcframeworks. */
		for (platformAndSdk, targets) in targetsByPlatformAndSdks {
			let firstTarget = targets.first! /* Safe because of the way targetsByPlatformAndSdks is built. */
			
			/* First let’s check all targets have the same headers and libs for
			 * this platform/sdk tuple, and also check all libs have the same
			 * bitcode status. */
			let builtTarget = builtTargets[firstTarget]! /* Safe because of the way builtTargets is built. */
			for target in targets {
				let currentBuiltTarget = builtTargets[target]! /* Safe because of the way builtTargets is built. */
				guard builtTarget.headers == currentBuiltTarget.headers else {
					struct IncompatibleHeadersBetweenTargetsForSamePlatformAndSdk : Error {
						var refTarget: Target
						var refHeaders: [FilePath]
						var currentTarget: Target
						var currentHeaders: [FilePath]
					}
					throw IncompatibleHeadersBetweenTargetsForSamePlatformAndSdk(
						refTarget: firstTarget, refHeaders: builtTarget.headers,
						currentTarget: target, currentHeaders: currentBuiltTarget.headers
					)
				}
				guard builtTarget.staticLibraries == currentBuiltTarget.staticLibraries else {
					struct IncompatibleLibsBetweenTargetsForSamePlatformAndSdk : Error {
						var refTarget: Target
						var refLibs: [FilePath]
						var currentTarget: Target
						var currentLibs: [FilePath]
					}
					throw IncompatibleLibsBetweenTargetsForSamePlatformAndSdk(
						refTarget: firstTarget, refLibs: builtTarget.staticLibraries,
						currentTarget: target, currentLibs: currentBuiltTarget.staticLibraries
					)
				}
			}
			
			/* Create FAT static libs, one per lib */
//			for lib in builtTarget.staticLibraries {
//				let dest = URL(fileURLWithPath: fatStaticDirectory, isDirectory: true).appendingPathComponent("\(platformAndSdk)").appendingPathComponent(lib)
//				guard !skipExistingArtifacts || !fm.fileExists(atPath: dest.path) else {
//					logger.info("Skipping creation of \(dest.path) because it already exists")
//					continue
//				}
//				try fm.ensureDirectory(path: dest.deletingLastPathComponent().path)
//				try fm.ensureFileDeleted(path: dest.path)
			
//				logger.info("Creating FAT lib \(dest.path) from \(targets.count) lib(s)")
//				try Process.spawnAndStreamEnsuringSuccess(
//					"/usr/bin/xcrun",
//					args: ["lipo", "-create"] + targets.map{ URL(fileURLWithPath: installsDirectory).appendingPathComponent("\($0)").appendingPathComponent(lib).path } + ["-output", dest.path],
//					outputHandler: Process.logProcessOutputFactory(logger: logger)
//				)
//			}
			
//			/* Create merged FAT static lib */
//			mergeFatStatic: do {
//				let dest = URL(fileURLWithPath: mergedFatStaticDirectory, isDirectory: true).appendingPathComponent("\(platformAndSdk)").appendingPathComponent("libOpenSSL.a")
//				guard !skipExistingArtifacts || !fm.fileExists(atPath: dest.path) else {
//					logger.info("Skipping creation of \(dest.path) because it already exists")
//					break mergeFatStatic
//				}
//				try fm.ensureDirectory(path: dest.deletingLastPathComponent().path)
//				try fm.ensureFileDeleted(path: dest.path)
			
//				logger.info("Merging \(libs.count) lib(s) to \(dest.path)")
//				try Process.spawnAndStreamEnsuringSuccess(
//					"/usr/bin/xcrun",
//					args: ["libtool", "-static", "-o", dest.path] + libs.map{ URL(fileURLWithPath: fatStaticDirectory, isDirectory: true).appendingPathComponent("\(platformAndSdk)").appendingPathComponent($0).path },
//					outputHandler: Process.logProcessOutputFactory(logger: logger)
//				)
//			}
			
//			/* Create FAT dylib from the dylibs generated earlier */
//			fatDylib: do {
//				let dest = URL(fileURLWithPath: mergedFatDynamicDirectory, isDirectory: true).appendingPathComponent("\(platformAndSdk)").appendingPathComponent("libOpenSSL.dylib")
//				guard !skipExistingArtifacts || !fm.fileExists(atPath: dest.path) else {
//					logger.info("Skipping creation of \(dest.path) because it already exists")
//					break fatDylib
//				}
//				try fm.ensureDirectory(path: dest.deletingLastPathComponent().path)
//				try fm.ensureFileDeleted(path: dest.path)
			
//				logger.info("Creating FAT dylib \(dest.path) from \(targets.count) lib(s)")
//				try Process.spawnAndStreamEnsuringSuccess(
//					"/usr/bin/xcrun",
//					args: ["lipo", "-create"] + targets.map{ URL(fileURLWithPath: dylibsDirectory).appendingPathComponent("\($0)").appendingPathComponent("libOpenSSL.dylib").path } + ["-output", dest.path],
//					outputHandler: Process.logProcessOutputFactory(logger: logger)
//				)
//			}
			
//			/* Create the framework from the dylib, headers, and other templates. */
//			framework: do {
//				let dest = URL(fileURLWithPath: finalFrameworksDirectory, isDirectory: true).appendingPathComponent("\(platformAndSdk)").appendingPathComponent("OpenSSL.framework")
//				guard !skipExistingArtifacts || !fm.fileExists(atPath: dest.path) else {
//					logger.info("Skipping creation of \(dest.path) because it already exists")
//					break framework
//				}
//				try fm.ensureDirectoryDeleted(path: dest.path)
//				try fm.ensureDirectory(path: dest.path)
//			}
		}
	}
	
	private struct PlatformAndSdk : Hashable, CustomStringConvertible {
		
		var platform: String
		var sdk: String
		
		var description: String {
			/* We assume the sdk and platform are valid (do not contain dashes). */
			return [sdk, platform].joined(separator: "-")
		}
		
	}
	
	private static var defaultFilesFolderURL: URL {
		var base = Bundle.main.bundleURL.deletingLastPathComponent()
		if base.pathComponents.contains("DerivedData") {
			base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		} else if base.pathComponents.contains(".build") {
			base = base.deletingLastPathComponent().deletingLastPathComponent()
		}
		return base.appendingPathComponent("Files")
	}
	
}
