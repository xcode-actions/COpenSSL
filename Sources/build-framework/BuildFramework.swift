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
	
	@Option(help: "Everything build-framework will create will be in this folder. The folder will be created if it does not exist.")
	var workdir = "./openssl-workdir"
	
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
		
		/* Contains the extracted tarball, config’d and built. One dir per target. */
		let sourcesDirectory = URL(fileURLWithPath: workdir).appendingPathComponent("step1_sources-and-builds").path
		/* The builds from the previous step are installed here. */
		let installsDirectory = URL(fileURLWithPath: workdir).appendingPathComponent("step2_installs").path
		/* OpenSSL has two libs we merged into one: COpenSSL. One dir per target. */
		let mergedStaticDirectory = URL(fileURLWithPath: workdir).appendingPathComponent("step3_merged-libs").appendingPathComponent("static").path
		let mergedDynamicDirectory = URL(fileURLWithPath: workdir).appendingPathComponent("step3_merged-libs").appendingPathComponent("dynamic").path
		/* Contains the fat libs, built from prev step. One dir per platform+sdk.
		 * We have to do this because xcodebuild does not do it automatically when
		 * building an xcframework (this is understandable), and an xcframework
		 * splits the underlying framework on platform+sdk, not platform+sdk+arch. */
		let mergedFatStaticDirectory = URL(fileURLWithPath: workdir).appendingPathComponent("step4_merged-fat-libs").appendingPathComponent("static").path
		let mergedFatDynamicDirectory = URL(fileURLWithPath: workdir).appendingPathComponent("step4_merged-fat-libs").appendingPathComponent("dynamic").path
		
		if clean {
			logger.info("Cleaning previous builds if applicable")
			try ensureDirectoryDeleted(path: sourcesDirectory, fileManager: fm)
			try ensureDirectoryDeleted(path: installsDirectory, fileManager: fm)
			try ensureDirectoryDeleted(path: mergedStaticDirectory, fileManager: fm)
			try ensureDirectoryDeleted(path: mergedDynamicDirectory, fileManager: fm)
			try ensureDirectoryDeleted(path: mergedFatStaticDirectory, fileManager: fm)
			try ensureDirectoryDeleted(path: mergedFatDynamicDirectory, fileManager: fm)
		}
		
		try ensureDirectory(path: workdir, fileManager: fm)
		try ensureDirectory(path: sourcesDirectory, fileManager: fm)
		try ensureDirectory(path: installsDirectory, fileManager: fm)
		try ensureDirectory(path: mergedStaticDirectory, fileManager: fm)
		try ensureDirectory(path: mergedDynamicDirectory, fileManager: fm)
		try ensureDirectory(path: mergedFatStaticDirectory, fileManager: fm)
		try ensureDirectory(path: mergedFatDynamicDirectory, fileManager: fm)
		
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
		for target in targets {
			let sourceDirectoryURL = URL(fileURLWithPath: sourcesDirectory).appendingPathComponent("\(target)")
			let installDirectoryURL = URL(fileURLWithPath: installsDirectory).appendingPathComponent("\(target)")
			let extractedSourceDirectoryURL = sourceDirectoryURL.appendingPathComponent(localTarballURL.deletingPathExtension().deletingPathExtension().lastPathComponent)
			
			guard !skipExistingArtefacts || !fm.fileExists(atPath: installDirectoryURL.path) else {
				logger.info("Skipping building of target \(target) because \(installDirectoryURL.path) exists")
				continue
			}
			
			/* Extract tarball in source directory. If the tarball was already
			 * there, tar will overwrite existing files. */
			try ensureDirectory(path: sourceDirectoryURL.path, fileManager: fm)
			try Process.spawnAndStreamEnsuringSuccess("/usr/bin/tar", args: ["xf", localTarballURL.path, "-C", sourceDirectoryURL.path], outputHandler: Process.logProcessOutputFactory(logger: logger))
			
			var isDir = ObjCBool(false)
			guard fm.fileExists(atPath: extractedSourceDirectoryURL.path, isDirectory: &isDir), isDir.boolValue else {
				struct ExtractedTarballNotFound : Error {var expectedPath: String}
				throw ExtractedTarballNotFound(expectedPath: extractedSourceDirectoryURL.path)
			}
			
			logger.info("Building for target \(target)")
			try buildAndInstallOpenSSL(
				sourceDirectory: extractedSourceDirectoryURL, installDirectory: installDirectoryURL,
				target: target, devDir: developerDir, fileManager: fm, logger: logger
			)
		}
		
		/* Merge libcrypto.a and libssl.a in a single static lib. */
		for target in targets {
			
		}
		
		/* Merge libcrypto.a and libssl.a in a single dynamic lib. */
		for target in targets {
			/* TODO */
		}
	}
	
	var numberOfCores: Int? = {
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
	
	private func buildAndInstallOpenSSL(sourceDirectory: URL, installDirectory: URL, target: Target, devDir: String, fileManager fm: FileManager, logger: Logger) throws {
		/* Apparently we *have to* change the CWD */
		fm.changeCurrentDirectoryPath(sourceDirectory.path)
		
		/* Prepare -j option for make */
		let multicoreMakeOption = numberOfCores.flatMap{ ["-j", "\($0)"] } ?? []
		
		/* *** Configure *** */
		setenv("CROSS_COMPILE",              "\(devDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/", 1)
		setenv("OPENSSLBUILD_SDKs_LOCATION", "\(devDir)/Platforms/\(target.platformLegacyName).platform/Developer", 1)
		setenv("OPENSSLBUILD_SDK",           "\(target.platformLegacyName).sdk", 1) // TODO: SDK version overrides
		setenv("OPENSSL_LOCAL_CONFIG_DIR",   "/Users/frizlab/Documents/Private/COpenSSL/Files/OpenSSLConfigs", 1)
		let configArgs = [
			"\(target)",
			"--prefix=\(installDirectory.path)",
			"no-async",
			"no-shared",
			"no-tests"
		] + (target.arch.hasSuffix("64") ? ["enable-ec_nistp_64_gcc_128"] : [])
		try Process.spawnAndStreamEnsuringSuccess(sourceDirectory.appendingPathComponent("Configure").path, args: configArgs, outputHandler: Process.logProcessOutputFactory(logger: logger))
		
		/* *** Build *** */
		try Process.spawnAndStreamEnsuringSuccess("/usr/bin/make", args: multicoreMakeOption, outputHandler: Process.logProcessOutputFactory(logger: logger))
		
		/* *** Install *** */
		try Process.spawnAndStreamEnsuringSuccess("/usr/bin/make", args: ["install_sw"] + multicoreMakeOption, outputHandler: Process.logProcessOutputFactory(logger: logger))
	}
	
}
