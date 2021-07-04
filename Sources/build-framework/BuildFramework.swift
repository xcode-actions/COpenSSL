import CryptoKit
import Foundation

import ArgumentParser
import CLTLogger
import Logging
import SystemPackage
import XcodeTools
import XibLoc



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
	var clean = false
	
	@Flag
	var skipExistingArtefacts = false
	
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
		
		let developerDir = try Process.spawnAndGetOutput("/usr/bin/xcode-select", args: ["-print-path"])
			.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
		logger.debug("Using Developer dir \(developerDir)")
		
		let fm = FileManager.default
		
		let workDirURL = URL(fileURLWithPath: workdir, isDirectory: true)
		let resultDirURL = URL(fileURLWithPath: resultdir ?? workdir, isDirectory: true)
		let buildDirURL = workDirURL.appendingPathComponent("build")
		
		let staticXCFrameworkURL = resultDirURL.appendingPathComponent("COpenSSL-static").appendingPathExtension("xcframework")
		let dynamicXCFrameworkURL = resultDirURL.appendingPathComponent("COpenSSL-dynamic").appendingPathExtension("xcframework")
		
		/* Contains the extracted tarball, config’d and built. One dir per target. */
		let sourcesDirectory = buildDirURL.appendingPathComponent("step1.sources-and-builds").path
		/* The builds from the previous step are installed here. */
		let installsDirectory = buildDirURL.appendingPathComponent("step2.installs").path
		let fatStaticDirectory = buildDirURL.appendingPathComponent("step3.lib-derivatives").appendingPathComponent("fat-static-libs").path
		let libObjectsDirectory = buildDirURL.appendingPathComponent("step3.lib-derivatives").appendingPathComponent("lib-objects").path
		let dylibsDirectory = buildDirURL.appendingPathComponent("step3.lib-derivatives").appendingPathComponent("merged-dynamic-libs").path
		/* Contains the fat libs, built from prev step. One dir per platform+sdk.
		 * We have to do this because xcodebuild does not do it automatically when
		 * building an xcframework (this is understandable), and an xcframework
		 * splits the underlying framework on platform+sdk, not platform+sdk+arch. */
		let mergedFatStaticDirectory = buildDirURL.appendingPathComponent("step4.merged-fat-libs").appendingPathComponent("static").path
		let mergedFatDynamicDirectory = buildDirURL.appendingPathComponent("step4.merged-fat-libs").appendingPathComponent("dynamic").path
		/* Contains the dynamic frameworks. The static xcframework will be built
		 * directly from the FAT .a and headers, but the dynamic one needs fully
		 * built frameworks */
		let frameworksDirectory = buildDirURL.appendingPathComponent("step5.frameworks").path
		
		if clean {
			logger.info("Cleaning previous builds if applicable")
			try fm.ensureDirectoryDeleted(path: buildDirURL.path)
			try fm.ensureDirectoryDeleted(path: staticXCFrameworkURL.path)
			try fm.ensureDirectoryDeleted(path: dynamicXCFrameworkURL.path)
		}
		
		try fm.ensureDirectory(path: workdir)
		try fm.ensureDirectory(path: buildDirURL.path)
		try fm.ensureDirectory(path: sourcesDirectory)
		try fm.ensureDirectory(path: installsDirectory)
		try fm.ensureDirectory(path: fatStaticDirectory)
		try fm.ensureDirectory(path: libObjectsDirectory)
		try fm.ensureDirectory(path: dylibsDirectory)
		try fm.ensureDirectory(path: mergedFatStaticDirectory)
		try fm.ensureDirectory(path: mergedFatDynamicDirectory)
		try fm.ensureDirectory(path: frameworksDirectory)
		
		fm.changeCurrentDirectoryPath(workdir)
		
		let tarballStringURL = opensslBaseURL.applying(xibLocInfo: Str2StrXibLocInfo(simpleSourceTypeReplacements: [OneWordTokens(leftToken: "{{", rightToken: "}}"): { _ in opensslVersion }], identityReplacement: { $0 })!)
		logger.debug("Tarball URL as string: \(tarballStringURL)")
		
		guard let tarballURL = URL(string: tarballStringURL) else {
			struct TarballURLIsNotValid : Error {var stringURL: String}
			throw TarballURLIsNotValid(stringURL: tarballStringURL)
		}
		
		/* Downloading tarball if needed */
		let localTarballURL = URL(fileURLWithPath: tarballURL.lastPathComponent)
		if fm.fileExists(atPath: localTarballURL.path), try checkChecksum(file: localTarballURL, expectedChecksum: expectedTarballShasum) {
			/* File exists and already has correct checksum (or checksum is not checked) */
			logger.info("Reusing downloaded tarball at path \(localTarballURL.path)")
		} else {
			logger.info("Downloading tarball from \(tarballURL)")
			let (tmpFileURL, urlResponse) = try await URLSession.shared.download(from: tarballURL, delegate: nil)
			guard let httpURLResponse = urlResponse as? HTTPURLResponse, 200..<300 ~= httpURLResponse.statusCode else {
				struct InvalidURLResponse : Error {var response: URLResponse}
				throw InvalidURLResponse(response: urlResponse)
			}
			guard try checkChecksum(file: tmpFileURL, expectedChecksum: expectedTarballShasum) else {
				struct InvalidChecksumForDownloadedTarball : Error {}
				throw InvalidChecksumForDownloadedTarball()
			}
			_ = try? fm.removeItem(at: localTarballURL)
			try fm.moveItem(at: tmpFileURL, to: localTarballURL)
			logger.info("Tarball downloaded")
		}
		
		/* Build all the variants we need. Note only static libs are built because
		 * we merge them later in a single dyn lib to create a single framework. */
		var headersByTargets = [Target: [String]]() /* Key is target, value is array of relative path from install dir (e.g. "include/openssl/aes.h") */
		var staticLibsByTargets = [Target: [String]]() /* Key is target, value is array of relative path from install dir (e.g. "lib/libcrypto.a") */
		for target in targets {
			let sourceDirectoryURL = URL(fileURLWithPath: sourcesDirectory).appendingPathComponent("\(target)")
			let installDirectoryURL = URL(fileURLWithPath: installsDirectory).appendingPathComponent("\(target)")
			
			/* First build OpenSSL */
			try extractBuildAndInstallOpenSSLIfNeeded(
				tarballURL: localTarballURL,
				sourceDirectory: sourceDirectoryURL, installDirectory: installDirectoryURL,
				target: target, devDir: developerDir, fileManager: fm, logger: logger
			)
			
			/* Then retrieve the list of files we care about */
			let exclusions = try [
				NSRegularExpression(pattern: #"^\.DS_Store$"#, options: []),
				NSRegularExpression(pattern: #"/\.DS_Store$"#, options: [])
			]
			var headers = [String]()
			var staticLibs = [String]()
			try ListFiles.iterateFiles(in: installDirectoryURL, exclude: exclusions, handler: { url, relativePath, isDir in
				func checkFileLocation(expectedLocation: [String], fileType: String) {
					if relativePath.components(separatedBy: "/").dropLast() != expectedLocation {
						logger.warning("found \(fileType) at unexpected location: \(relativePath)", metadata: ["target": "\(target)", "path_root": "\(installDirectoryURL.path)"])
					}
				}
				
				switch (isDir, url.pathExtension) {
					case (true, _): (/*nop*/)
						
					case (false, "a"):
						/* We found a static lib. Let’s check its location and add it. */
						checkFileLocation(expectedLocation: ["lib"], fileType: "lib")
						staticLibs.append(relativePath)
						
					case (false, "h"):
						/* We found a header lib. Let’s check its location and add it. */
						checkFileLocation(expectedLocation: ["include", "openssl"], fileType: "header")
						headers.append(relativePath)
						
					case (false, ""):
						/* Binary. We don’t care about binaries. But let’s check it is
						 * at an expected location. */
						checkFileLocation(expectedLocation: ["bin"], fileType: "binary")
						
					case (false, "pc"):
						/* pkgconfig file. We don’t care about those. But let’s check
						 * this one is at an expected location. */
						checkFileLocation(expectedLocation: ["lib", "pkgconfig"], fileType: "pc file")
						
					case (false, _):
						logger.warning("found unknown file: \(relativePath)", metadata: ["target": "\(target)", "path_root": "\(installDirectoryURL.path)"])
				}
				return true
			})
			assert(headersByTargets[target] == nil)
			assert(staticLibsByTargets[target] == nil)
			headersByTargets[target] = headers
			staticLibsByTargets[target] = staticLibs
			
			let staticLibURLs = staticLibs.map{ installDirectoryURL.appendingPathComponent($0) }
			
			/* Let’s extract the static libraries’ objects in a folder. We’ll use
			 * this to build the dynamic libraries. */
			libObjects: do {
				let destinationDirectory = URL(fileURLWithPath: libObjectsDirectory).appendingPathComponent("\(target)")
				guard !skipExistingArtefacts || !fm.fileExists(atPath: destinationDirectory.path) else {
					logger.info("Skipping static lib extract for target \(target) because \(destinationDirectory.path) already exists")
					break libObjects
				}
				try fm.ensureDirectoryDeleted(path: destinationDirectory.path)
				try fm.ensureDirectory(path: destinationDirectory.path)
				
				/* Apparently we *have to* change the CWD (though we should do it
				 * through Process which has an API for that). */
				let previousCwd = fm.currentDirectoryPath
				fm.changeCurrentDirectoryPath(destinationDirectory.path)
				defer {fm.changeCurrentDirectoryPath(previousCwd)}
				
				for staticLibURL in staticLibURLs {
					let fullStaticLibPath = staticLibURL.path
					logger.info("Extracting \(fullStaticLibPath) to \(destinationDirectory.path)")
					try Process.spawnAndStreamEnsuringSuccess(
						"/usr/bin/xcrun",
						args: ["ar", "-x", fullStaticLibPath],
						outputHandler: Process.logProcessOutputFactory(logger: logger)
					)
				}
			}
			
			/* Now we build the dynamic libraries. We’ll use those to get FAT
			 * dynamic libraries later. */
			dylibs: do {
				let destination = URL(fileURLWithPath: dylibsDirectory).appendingPathComponent("\(target)").appendingPathComponent("libOpenSSL.dylib")
				guard !skipExistingArtefacts || !fm.fileExists(atPath: destination.path) else {
					logger.info("Skipping dynamic lib creation for target \(target) because \(destination.path) already exists")
					break dylibs
				}
				try fm.ensureDirectoryDeleted(path: destination.deletingLastPathComponent().path)
				try fm.ensureDirectory(path: destination.deletingLastPathComponent().path)
				
				let (sdk, minSdk) = try getSdkVersions(staticLibURLs, logger: logger)
				logger.debug("got sdk \(sdk), min sdk \(minSdk)", metadata: ["target": "\(target)"])
				
				let objectDirectory = URL(fileURLWithPath: libObjectsDirectory).appendingPathComponent("\(target)")
				let objectFiles = try fm.contentsOfDirectory(atPath: objectDirectory.path).filter{ $0.hasSuffix(".o") }.map{ objectDirectory.appendingPathComponent($0).path }
				logger.info("Creating dylib at \(destination.path) from objects in \(objectDirectory.path)")
				try Process.spawnAndStreamEnsuringSuccess(
					"/usr/bin/xcrun",
					args: ["ld"] + objectFiles + [
						"-dylib", "-lSystem",
						"-application_extension",
						"-bitcode_bundle",
						"-arch", target.arch,
						"-platform_version", target.platformVersionName, minSdk, sdk,
						"-syslibroot", "\(developerDir)/Platforms/\(target.platformLegacyName).platform/Developer/SDKs/\(target.platformLegacyName).sdk",
						"-compatibility_version", normalizedOpenSSLVersion(opensslVersion), /* Not true, but we do not care; the resulting lib will be in a framework which will be embedded in the app and not reused 99.99% of the time, so… */
						"-current_version", normalizedOpenSSLVersion(opensslVersion),
						"-o", destination.path
					],
					outputHandler: Process.logProcessOutputFactory(logger: logger)
				)
				#warning("Remember to do this when we create the dynamic framework")
//				logger.info("Updating install name of dylib at \(destination.path)")
//				try Process.spawnAndStreamEnsuringSuccess(
//					"/usr/bin/xcrun",
//					args: ["install_name_tool", "-id", "@rpath/OpenSSL.framework/OpenSSL", destination.path],
//					outputHandler: Process.logProcessOutputFactory(logger: logger)
//				)
			}
		}
		
		let targetsByPlatformAndSdks = Dictionary(grouping: targets, by: { PlatformAndSdk(platform: $0.platform, sdk: $0.sdk) })
		
		/* Create one FAT static lib and one FAT dylib per platform+sdk w/ some
		 * derivatives first to get there.
		 * Also validate all the targets in a platform+sdk tuple have the same
		 * headers. If they don’t, we won’t be able to use the same headers to
		 * create a single framework for the tuple. */
		for (platformAndSdk, targets) in targetsByPlatformAndSdks {
			let firstTarget = targets.first! /* Safe because of the way targetsByPlatformAndSdks is built. */
			
			/* First let’s check all targets have the same headers and libs for
			 * this platform/sdk tuple */
			let libs = staticLibsByTargets[targets.first!, default: []]
			let headers = headersByTargets[targets.first!, default: []]
			for target in targets {
				let currentLibs = staticLibsByTargets[target, default: []]
				let currentHeaders = headersByTargets[target, default: []]
				guard currentHeaders == headers else {
					struct IncompatibleHeadersBetweenTargetsForSamePlatformAndSdk : Error {
						var refTarget: Target
						var refHeaders: [String]
						var currentTarget: Target
						var currentHeaders: [String]
					}
					throw IncompatibleHeadersBetweenTargetsForSamePlatformAndSdk(
						refTarget: firstTarget, refHeaders: headers,
						currentTarget: target, currentHeaders: currentHeaders
					)
				}
				guard currentLibs == libs else {
					struct IncompatibleLibsBetweenTargetsForSamePlatformAndSdk : Error {
						var refTarget: Target
						var refLibs: [String]
						var currentTarget: Target
						var currentLibs: [String]
					}
					throw IncompatibleLibsBetweenTargetsForSamePlatformAndSdk(
						refTarget: firstTarget, refLibs: libs,
						currentTarget: target, currentLibs: currentLibs
					)
				}
			}
			
			/* Create FAT static libs, one per lib */
			for lib in libs {
				let dest = URL(fileURLWithPath: fatStaticDirectory, isDirectory: true).appendingPathComponent("\(platformAndSdk)").appendingPathComponent(lib)
				guard !skipExistingArtefacts || !fm.fileExists(atPath: dest.path) else {
					logger.info("Skipping creation of \(dest.path) because it already exists")
					continue
				}
				try fm.ensureDirectory(path: dest.deletingLastPathComponent().path)
				try fm.ensureFileDeleted(path: dest.path)
				
				logger.info("Creating FAT lib \(dest.path) from \(targets.count) lib(s)")
				try Process.spawnAndStreamEnsuringSuccess(
					"/usr/bin/xcrun",
					args: ["lipo", "-create"] + targets.map{ URL(fileURLWithPath: installsDirectory).appendingPathComponent("\($0)").appendingPathComponent(lib).path } + ["-output", dest.path],
					outputHandler: Process.logProcessOutputFactory(logger: logger)
				)
			}
			
			/* Create merged FAT static lib */
			mergeFatStatic: do {
				let dest = URL(fileURLWithPath: mergedFatStaticDirectory, isDirectory: true).appendingPathComponent("\(platformAndSdk)").appendingPathComponent("libOpenSSL.a")
				guard !skipExistingArtefacts || !fm.fileExists(atPath: dest.path) else {
					logger.info("Skipping creation of \(dest.path) because it already exists")
					break mergeFatStatic
				}
				try fm.ensureDirectory(path: dest.deletingLastPathComponent().path)
				try fm.ensureFileDeleted(path: dest.path)
				
				logger.info("Merging \(libs.count) lib(s) to \(dest.path)")
				try Process.spawnAndStreamEnsuringSuccess(
					"/usr/bin/xcrun",
					args: ["libtool", "-static", "-o", dest.path] + libs.map{ URL(fileURLWithPath: fatStaticDirectory, isDirectory: true).appendingPathComponent("\(platformAndSdk)").appendingPathComponent($0).path },
					outputHandler: Process.logProcessOutputFactory(logger: logger)
				)
			}
			
			/* Create FAT dylib from the dylibs generated earlier */
			fatDylib: do {
				let dest = URL(fileURLWithPath: mergedFatDynamicDirectory, isDirectory: true).appendingPathComponent("\(platformAndSdk)").appendingPathComponent("libOpenSSL.dylib")
				guard !skipExistingArtefacts || !fm.fileExists(atPath: dest.path) else {
					logger.info("Skipping creation of \(dest.path) because it already exists")
					break fatDylib
				}
				try fm.ensureDirectory(path: dest.deletingLastPathComponent().path)
				try fm.ensureFileDeleted(path: dest.path)
				
				logger.info("Creating FAT dylib \(dest.path) from \(targets.count) lib(s)")
				try Process.spawnAndStreamEnsuringSuccess(
					"/usr/bin/xcrun",
					args: ["lipo", "-create"] + targets.map{ URL(fileURLWithPath: dylibsDirectory).appendingPathComponent("\($0)").appendingPathComponent("libOpenSSL.dylib").path } + ["-output", dest.path],
					outputHandler: Process.logProcessOutputFactory(logger: logger)
				)
			}
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
			base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		} else if base.pathComponents.contains(".build") {
			base = base.deletingLastPathComponent().deletingLastPathComponent()
		}
		return base.appendingPathComponent("Files")
	}
	
	private var numberOfCores: Int? = {
		guard MemoryLayout<Int32>.size <= MemoryLayout<Int>.size else {
//			logger.notice("Int32 is bigger than Int (\(MemoryLayout<Int32>.size) > \(MemoryLayout<Int>.size)). Cannot return the number of cores.")
			return nil
		}
		
		var ncpu: Int32 = 0
		var len = MemoryLayout.size(ofValue: ncpu)
		
		var mib = [CTL_HW, HW_NCPU]
		let namelen = u_int(mib.count)
		
		guard sysctl(&mib, namelen, &ncpu, &len, nil, 0) == 0 else {return nil}
		return Int(ncpu)
	}()
	
	private func checkChecksum(file: URL, expectedChecksum: String?) throws -> Bool {
		guard let expectedChecksum = expectedChecksum else {
			return true
		}
		
		let fileContents = try Data(contentsOf: file)
		return SHA256.hash(data: fileContents).reduce("", { $0 + String(format: "%02x", $1) }) == expectedChecksum.lowercased()
	}
	
	private func normalizedOpenSSLVersion(_ version: String) -> String {
		if let letter = version.last, let ascii = letter.asciiValue, letter.isLetter, letter.isLowercase {
			/* We probably have a version of the for “1.2.3a” (we should do more
			 * checks but it’s late and I’m lazy).
			 * Let’s convert the letter to a number (a=01, b=02, j=10, etc.) and
			 * replace it with the number.
			 * For 1.2.3a for instance, we get 1.2.301 */
			let base = version.dropLast()
			let value = ascii - Character("a").asciiValue! + 1
			return base + String(format: "%02d", value)
		}
		/* TODO: I think we’ll have to drop the beta from beta versions. */
		return version
	}
	
	/* Inspect Mach-O load commands to get minimum SDK version.
	 *
	 * Depending on the actual minimum SDK version it may look like this for
	 * modern SDKs:
	 *
	 *     Load command 1
	 *            cmd LC_BUILD_VERSION
	 *        cmdsize 24
	 *       platform 8
	 *            sdk 13.2                   <-- target SDK
	 *          minos 12.0                   <-- minimum SDK
	 *         ntools 0
	 *
	 * Or like this for older versions, with a platform-dependent tag:
	 *
	 *     Load command 1
	 *           cmd LC_VERSION_MIN_WATCHOS
	 *       cmdsize 16
	 *       version 4.0                     <-- minimum SDK
	 *           sdk 6.1                     <-- target SDK */
	private func getSdkVersions(_ libs: [URL], logger: Logger) throws -> (sdk: String, minSdk: String) {
		var sdk: String?
		var minSdk: String?
		for lib in libs {
			var error: Error?
			var lastCommand: String?
			let outputHandler: (String, FileDescriptor) -> Void = { line, fd in
				guard error == nil else {return}
				
				let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
				let lastWord = String(trimmedLine.split(separator: " ").last ?? "")
				switch fd {
					case .standardOutput:
						switch trimmedLine {
							case let str where str.hasPrefix("Load command "): lastCommand = nil
							case let str where str.hasPrefix("cmd "):          lastCommand = lastWord
							case let str where (
								(str.hasPrefix("minos ")   && lastCommand == "LC_BUILD_VERSION") ||
								(str.hasPrefix("version ") && (lastCommand ?? "").hasPrefix("LC_VERSION_MIN_"))
							):
								if minSdk == nil {minSdk = lastWord}
								else {
									guard minSdk == lastWord else {
										logger.error("found min sdk \(lastWord) but current min sdk is \(minSdk ?? "<nil>")")
										struct MultipleMinSdkVersionFound : Error {var libs: [URL]}
										error = MultipleMinSdkVersionFound(libs: libs)
										return
									}
								}
							case let str where (
								str.hasPrefix("sdk ") && (lastCommand == "LC_BUILD_VERSION" || (lastCommand ?? "").hasPrefix("LC_VERSION_MIN_"))
							):
								guard lastWord != "n/a" else {return}
								if sdk == nil {sdk = lastWord}
								else {
									guard sdk == lastWord else {
										logger.error("found sdk \(lastWord) but current sdk is \(sdk ?? "<nil>")")
										struct MultipleSdkVersionFound : Error {var libs: [URL]}
										error = MultipleSdkVersionFound(libs: libs)
										return
									}
								}
								
							default: (/*nop: we simply ignore the line*/)
						}
						
					case .standardError: logger.debug("otool trimmed stderr: \(trimmedLine)")
					default:             logger.debug("otool trimmed unknown fd: \(trimmedLine)")
				}
			}
			try Process.spawnAndStreamEnsuringSuccess(
				"/usr/bin/xcrun",
				args: ["otool", "-l", lib.path],
				outputHandler: outputHandler
			)
			if let e = error {throw e}
		}
		guard let sdkNonOptional = sdk else {
			struct CannotGetSdk : Error {var libs: [URL]}
			throw CannotGetSdk(libs: libs)
		}
		guard let minSdkNonOptional = minSdk else {
			struct CannotGetMinSdk : Error {var libs: [URL]}
			throw CannotGetMinSdk(libs: libs)
		}
		return (sdkNonOptional, minSdkNonOptional)
	}
	
	private func extractBuildAndInstallOpenSSLIfNeeded(tarballURL: URL, sourceDirectory: URL, installDirectory: URL, target: Target, devDir: String, fileManager fm: FileManager, logger: Logger) throws {
		guard !skipExistingArtefacts || !fm.fileExists(atPath: installDirectory.path) else {
			logger.info("Skipping building of target \(target) because \(installDirectory.path) exists")
			return
		}
		
		let extractedSourceDirectoryURL = sourceDirectory.appendingPathComponent(tarballURL.deletingPathExtension().deletingPathExtension().lastPathComponent)
		
		/* Extract tarball in source directory. If the tarball was already
		 * there, tar will overwrite existing files (but does not remove
		 * additional files). */
		try fm.ensureDirectory(path: sourceDirectory.path)
		try Process.spawnAndStreamEnsuringSuccess("/usr/bin/tar", args: ["xf", tarballURL.path, "-C", sourceDirectory.path], outputHandler: Process.logProcessOutputFactory(logger: logger))
		
		var isDir = ObjCBool(false)
		guard fm.fileExists(atPath: extractedSourceDirectoryURL.path, isDirectory: &isDir), isDir.boolValue else {
			struct ExtractedTarballNotFound : Error {var expectedPath: String}
			throw ExtractedTarballNotFound(expectedPath: extractedSourceDirectoryURL.path)
		}
		
		logger.info("Building for target \(target)")
		try buildAndInstallOpenSSL(
			sourceDirectory: extractedSourceDirectoryURL, installDirectory: installDirectory,
			target: target, devDir: devDir, configsDir: URL(fileURLWithPath: filesPath).appendingPathComponent("OpenSSLConfigs").appendingPathComponent(opensslVersion).path,
			fileManager: fm, logger: logger
		)
	}
	
	private func buildAndInstallOpenSSL(sourceDirectory: URL, installDirectory: URL, target: Target, devDir: String, configsDir: String, fileManager fm: FileManager, logger: Logger) throws {
		/* Apparently we *have to* change the CWD (though we should do it through
		 * Process which has an API for that). */
		let previousCwd = fm.currentDirectoryPath
		fm.changeCurrentDirectoryPath(sourceDirectory.path)
		defer {fm.changeCurrentDirectoryPath(previousCwd)}
		
		/* Prepare -j option for make */
		let multicoreMakeOption = numberOfCores.flatMap{ ["-j", "\($0)"] } ?? []
		
		/* *** Configure *** */
		let sdkVersion: String?
		let minSDKVersion: String?
		switch target.platform {
			case   "macOS": (sdkVersion, minSDKVersion) = (  macOSSDKVersion,   macOSMinSDKVersion)
			case     "iOS": (sdkVersion, minSDKVersion) = (    iOSSDKVersion,     iOSMinSDKVersion)
			case    "tvOS": (sdkVersion, minSDKVersion) = (   tvOSSDKVersion,    tvOSMinSDKVersion)
			case "watchOS": (sdkVersion, minSDKVersion) = (watchOSSDKVersion, watchOSMinSDKVersion)
			default:        (sdkVersion, minSDKVersion) = (nil, nil)
		}
		setenv("CROSS_COMPILE",              "\(devDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/", 1)
		setenv("OPENSSLBUILD_SDKs_LOCATION", "\(devDir)/Platforms/\(target.platformLegacyName).platform/Developer", 1)
		setenv("OPENSSLBUILD_SDK",           "\(target.platformLegacyName)\(sdkVersion ?? "").sdk", 1)
		setenv("OPENSSL_LOCAL_CONFIG_DIR",   configsDir, 1)
		if let sdkVersion = sdkVersion {setenv("OPENSSLBUILD_SDKVERSION", sdkVersion, 1)}
		else                           {unsetenv("OPENSSLBUILD_SDKVERSION")}
		if let minSDKVersion = minSDKVersion {setenv("OPENSSLBUILD_MIN_SDKVERSION", minSDKVersion, 1)}
		else                                 {unsetenv("OPENSSLBUILD_MIN_SDKVERSION")}
		/* We currently do not support disabling bitcode (because we do not check
		 * if bitcode is enabled when calling ld later, and ld fails for some
		 * target if called with bitcode when linking objects that do not have
		 * bitcode). */
//		if disableBitcode {setenv("OPENSSLBUILD_DISABLE_BITCODE", "true", 1)}
//		else              {unsetenv("OPENSSLBUILD_DISABLE_BITCODE")}
		let configArgs = [
			"\(target)",
			"--prefix=\(installDirectory.path)",
			"no-async",
			"no-shared",
			"no-tests"
		] + (target.arch.hasSuffix("64") ? ["enable-ec_nistp_64_gcc_128"] : [])
		try Process.spawnAndStreamEnsuringSuccess(sourceDirectory.appendingPathComponent("Configure").path, args: configArgs, outputHandler: Process.logProcessOutputFactory(logger: logger))
		
		/* *** Build *** */
		try Process.spawnAndStreamEnsuringSuccess("/usr/bin/xcrun", args: ["make"] + multicoreMakeOption, outputHandler: Process.logProcessOutputFactory(logger: logger))
		
		/* *** Install *** */
		try Process.spawnAndStreamEnsuringSuccess("/usr/bin/xcrun", args: ["make", "install_sw"] + multicoreMakeOption, outputHandler: Process.logProcessOutputFactory(logger: logger))
	}
	
}
