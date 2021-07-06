import Foundation

import Logging
import SystemPackage



@available(macOS 12.0, *) // TODO: Remove when v12 exists in Package.swift
struct BuiltTarget {
	
	var target: Target
	
	var sourceFolder: FilePath
	var installFolder: FilePath
	
	/** Paths of the static libraries, _relative to the install folder_. */
	var staticLibraries: [FilePath]
	/** Paths of the dynamic libraries, _relative to the install folder_. */
	var dynamicLibraries: [FilePath]
	/** Paths of the headers, _relative to the install folder_. */
	var headers: [FilePath]
	/** Paths of the resources, _relative to the install folder_. */
	var resources: [FilePath]
	
	/** The list of static libraries absolute paths.
	 
	 We do **not** check whether the static libraries paths all resolve to a path
	 inside the install folder. They should though. */
	var absoluteStaticLibrariesPaths: [FilePath] {
		return staticLibraries.map{ installFolder.pushing($0) }
	}
	
	/** Returns an absolute FilePath */
	func buildDylibFromStaticLibs(opensslVersion: String, buildPaths: BuildPaths, skipExistingArtifacts: Bool, fileManager fm: FileManager, logger: Logger) throws -> FilePath {
		try buildLibObjects(buildPaths: buildPaths, skipExistingArtifacts: skipExistingArtifacts, fileManager: fm, logger: logger)
		return try buildDylib(opensslVersion: opensslVersion, buildPaths: buildPaths, skipExistingArtifacts: skipExistingArtifacts, fileManager: fm, logger: logger)
	}
	
	private func buildLibObjects(buildPaths: BuildPaths, skipExistingArtifacts: Bool, fileManager fm: FileManager, logger: Logger) throws {
		/* Let’s extract the static libraries’ objects in a folder. We’ll use this
		 * to build the dynamic libraries. */
		let destinationDir = buildPaths.libObjectsDir(for: target)
		guard !skipExistingArtifacts || !fm.fileExists(atPath: destinationDir.string) else {
			logger.info("Skipping static lib extract for target \(target) because \(destinationDir) already exists")
			return
		}
		try fm.ensureDirectoryDeleted(path: destinationDir)
		try fm.ensureDirectory(path: destinationDir)
		
		/* Apparently we *have to* change the CWD (though we should do it through
		 * Process which has an API for that). */
		let previousCwd = fm.currentDirectoryPath
		fm.changeCurrentDirectoryPath(destinationDir.string)
		defer {fm.changeCurrentDirectoryPath(previousCwd)}
		
		for staticLibPath in absoluteStaticLibrariesPaths {
			logger.info("Extracting \(staticLibPath) to \(destinationDir)")
			try Process.spawnAndStreamEnsuringSuccess(
				"/usr/bin/xcrun",
				args: ["ar", "-x", staticLibPath.string],
				outputHandler: Process.logProcessOutputFactory(logger: logger)
			)
		}
	}
	
	private func buildDylib(opensslVersion: String, buildPaths: BuildPaths, skipExistingArtifacts: Bool, fileManager fm: FileManager, logger: Logger) throws -> FilePath {
		/* Now we build the dynamic libraries. We’ll use those to get FAT dynamic
		 * libraries later. */
		let destination = buildPaths.dylibsDir(for: target).appending("libOpenSSL.dylib")
		guard !skipExistingArtifacts || !fm.fileExists(atPath: destination.string) else {
			logger.info("Skipping dynamic lib creation for target \(target) because \(destination) already exists")
			return destination
		}
		try fm.ensureDirectoryDeleted(path: destination.removingLastComponent())
		try fm.ensureDirectory(path: destination.removingLastComponent())
		
		let hasBitcode = try checkForBitcode(absoluteStaticLibrariesPaths, logger: logger)
		let (sdk, minSdk) = try getSdkVersions(absoluteStaticLibrariesPaths, logger: logger)
		logger.debug("got sdk \(sdk), min sdk \(minSdk)", metadata: ["target": "\(target)"])
		
		let objectDir = buildPaths.libObjectsDir(for: target)
		let objectFiles = try fm.contentsOfDirectory(atPath: objectDir.string).filter{ $0.hasSuffix(".o") }.map{ objectDir.appending($0) }
		logger.info("Creating dylib at \(destination) from objects in \(objectDir)")
		try Process.spawnAndStreamEnsuringSuccess(
			"/usr/bin/xcrun",
			args: ["ld"] + objectFiles.map{ $0.string } + (hasBitcode ? ["-bitcode_bundle"] : []) + [
				"-dylib", "-lSystem",
				"-application_extension",
				"-arch", target.arch,
				"-platform_version", target.platformVersionName, minSdk, sdk,
				"-syslibroot", "\(buildPaths.developerDir)/Platforms/\(target.platformLegacyName).platform/Developer/SDKs/\(target.platformLegacyName).sdk",
				"-compatibility_version", normalizedOpenSSLVersion(opensslVersion), /* Not true, but we do not care; the resulting lib will be in a framework which will be embedded in the app and not reused 99.99% of the time, so… */
				"-current_version", normalizedOpenSSLVersion(opensslVersion),
				"-o", destination.string
			],
			outputHandler: Process.logProcessOutputFactory(logger: logger)
		)
		#warning("Remember to do this when we create the dynamic framework")
//		logger.info("Updating install name of dylib at \(destination.path)")
//		try Process.spawnAndStreamEnsuringSuccess(
//			"/usr/bin/xcrun",
//			args: ["install_name_tool", "-id", "@rpath/OpenSSL.framework/OpenSSL", destination.path],
//			outputHandler: Process.logProcessOutputFactory(logger: logger)
//		)
		return destination
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
	private func getSdkVersions(_ libs: [FilePath], logger: Logger) throws -> (sdk: String, minSdk: String) {
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
										struct MultipleMinSdkVersionFound : Error {var libs: [FilePath]}
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
										struct MultipleSdkVersionFound : Error {var libs: [FilePath]}
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
				args: ["otool", "-l", lib.string],
				outputHandler: outputHandler
			)
			if let e = error {throw e}
		}
		guard let sdkNonOptional = sdk else {
			struct CannotGetSdk : Error {var libs: [FilePath]}
			throw CannotGetSdk(libs: libs)
		}
		guard let minSdkNonOptional = minSdk else {
			struct CannotGetMinSdk : Error {var libs: [FilePath]}
			throw CannotGetMinSdk(libs: libs)
		}
		return (sdkNonOptional, minSdkNonOptional)
	}
	
	/** If any lib contains bitcode, we return `true`.
	 
	 Something to explore for the detection:
	 
	    otool -v -s __LLVM __bundle path/to/lib
	 
	 Currently we use something along those lines:
	 
	    otool -l path/to/lib | grep __LLVM
	 
	 which is apparently [the Apple-recommended method](https://forums.developer.apple.com/message/7038)
	 (link is dead, it’s from [this stackoverflow comment](https://stackoverflow.com/questions/32808642#comment64079201_33615568)). */
	private func checkForBitcode(_ libs: [FilePath], logger: Logger) throws -> Bool {
		var foundLLVM = false
		var foundBitcode = false
		for lib in libs {
			var localFoundLLVM = false
			let outputHandler: (String, FileDescriptor) -> Void = { line, fd in
				guard !foundBitcode else {return}
				
				let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
				switch fd {
					case .standardOutput:
						localFoundLLVM = localFoundLLVM || trimmedLine.contains("__LLVM")
						foundBitcode   = foundBitcode   || trimmedLine.contains("__bitcode")
						foundLLVM      = foundLLVM      || localFoundLLVM
						
					case .standardError: logger.debug("otool trimmed stderr: \(trimmedLine)")
					default:             logger.debug("otool trimmed unknown fd: \(trimmedLine)")
				}
			}
			try Process.spawnAndStreamEnsuringSuccess(
				"/usr/bin/xcrun",
				args: ["otool", "-l", lib.string],
				outputHandler: outputHandler
			)
			if localFoundLLVM && !foundBitcode {
				logger.warning("__LLVM found in \(lib.string), but __bitcode was not (of lib is dynamic this is expected though)")
			}
			if foundBitcode {
				break
			}
		}
		return foundBitcode || foundLLVM
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
	
}
