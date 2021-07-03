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
	
	@Option(name: .customLong("macos-min-sdk-version"))
	var macOSMinSDKVersion = "10.15"
	
	@Option(name: .customLong("ios-min-sdk-version"))
	var iOSMinSDKVersion = "12.0"
	
	@Option
	var catalystMinSDKVersion="13.0"
	
	@Option(name: .customLong("watchos-min-sdk-version"))
	var watchOSMinSDKVersion="4.0"
	
	@Option(name: .customLong("tvos-min-sdk-version"))
	var tvOSMinSDKVersion="12.0"
	
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
			try ensureDirectoryDeleted(path: buildDirURL.path, fileManager: fm)
			try ensureDirectoryDeleted(path: staticXCFrameworkURL.path, fileManager: fm)
			try ensureDirectoryDeleted(path: dynamicXCFrameworkURL.path, fileManager: fm)
		}
		
		try ensureDirectory(path: workdir, fileManager: fm)
		try ensureDirectory(path: buildDirURL.path, fileManager: fm)
		try ensureDirectory(path: sourcesDirectory, fileManager: fm)
		try ensureDirectory(path: installsDirectory, fileManager: fm)
		try ensureDirectory(path: fatStaticDirectory, fileManager: fm)
		try ensureDirectory(path: libObjectsDirectory, fileManager: fm)
		try ensureDirectory(path: dylibsDirectory, fileManager: fm)
		try ensureDirectory(path: mergedFatStaticDirectory, fileManager: fm)
		try ensureDirectory(path: mergedFatDynamicDirectory, fileManager: fm)
		try ensureDirectory(path: frameworksDirectory, fileManager: fm)
		
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
						staticLibsByTargets[target, default: []].append(relativePath)
						
					case (false, "h"):
						/* We found a header lib. Let’s check its location and add it. */
						checkFileLocation(expectedLocation: ["include", "openssl"], fileType: "header")
						headersByTargets[target, default: []].append(relativePath)
						
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
			do {
				let dest = URL(fileURLWithPath: fatStaticDirectory, isDirectory: true).appendingPathComponent("\(platformAndSdk)").appendingPathComponent("OpenSSL.a")
			}
			let staticLibDestURL  = URL(fileURLWithPath: mergedFatStaticDirectory, isDirectory: true).appendingPathComponent("\(platformAndSdk)").appendingPathComponent("OpenSSL.a")
			let dynamicLibDestURL = URL(fileURLWithPath: mergedFatStaticDirectory, isDirectory: true).appendingPathComponent("\(platformAndSdk)").appendingPathComponent("OpenSSL.dylib")
			try ensureDirectory(path: staticLibDestURL.path,  fileManager: fm)
			try ensureDirectory(path: dynamicLibDestURL.path, fileManager: fm)
			
			/* Create merged FAT static lib */
//			try Process.spawnAndStreamEnsuringSuccess("/usr/bin/xcrun", args: ["lipo", "-create", ..., "-output", ], outputHandler: Process.logProcessOutputFactory(logger: logger))
			
			/* Create FAT dylib from static lib */
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
	
	private func ensureDirectory(path: String, fileManager fm: FileManager) throws {
		var isDir = ObjCBool(false)
		if !fm.fileExists(atPath: path, isDirectory: &isDir) {
			try fm.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true, attributes: nil)
		} else {
			guard isDir.boolValue else {
				struct ExpectedDir : Error {var path: String}
				throw ExpectedDir(path: path)
			}
		}
	}
	
	private func ensureDirectoryDeleted(path: String, fileManager fm: FileManager) throws {
		var isDir = ObjCBool(false)
		if fm.fileExists(atPath: path, isDirectory: &isDir) {
			guard isDir.boolValue else {
				struct ExpectedDir : Error {var path: String}
				throw ExpectedDir(path: path)
			}
			try fm.removeItem(at: URL(fileURLWithPath: path))
		}
	}
	
	private func checkChecksum(file: URL, expectedChecksum: String?) throws -> Bool {
		guard let expectedChecksum = expectedChecksum else {
			return true
		}
		
		let fileContents = try Data(contentsOf: file)
		return SHA256.hash(data: fileContents).reduce("", { $0 + String(format: "%02x", $1) }) == expectedChecksum.lowercased()
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
		try ensureDirectory(path: sourceDirectory.path, fileManager: fm)
		try Process.spawnAndStreamEnsuringSuccess("/usr/bin/tar", args: ["xf", tarballURL.path, "-C", sourceDirectory.path], outputHandler: Process.logProcessOutputFactory(logger: logger))
		
		var isDir = ObjCBool(false)
		guard fm.fileExists(atPath: extractedSourceDirectoryURL.path, isDirectory: &isDir), isDir.boolValue else {
			struct ExtractedTarballNotFound : Error {var expectedPath: String}
			throw ExtractedTarballNotFound(expectedPath: extractedSourceDirectoryURL.path)
		}
		
		logger.info("Building for target \(target)")
		#warning("Hard-coded conf path")
		try buildAndInstallOpenSSL(
			sourceDirectory: extractedSourceDirectoryURL, installDirectory: installDirectory,
			target: target, devDir: devDir, configsDir: "/Users/frizlab/Documents/Private/COpenSSL/Files/OpenSSLConfigs/\(opensslVersion)",
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
		setenv("CROSS_COMPILE",              "\(devDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/", 1)
		setenv("OPENSSLBUILD_SDKs_LOCATION", "\(devDir)/Platforms/\(target.platformLegacyName).platform/Developer", 1)
		setenv("OPENSSLBUILD_SDK",           "\(target.platformLegacyName).sdk", 1) // TODO: SDK version overrides
		setenv("OPENSSL_LOCAL_CONFIG_DIR",   configsDir, 1)
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
