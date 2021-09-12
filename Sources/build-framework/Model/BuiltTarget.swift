import Foundation
import System

import Logging
import SignalHandling
import SystemPackage
import XcodeTools



typealias FilePath = System.FilePath

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
	func buildDylibFromStaticLibs(opensslVersion: String, buildPaths: BuildPaths, skipExistingArtifacts: Bool) async throws -> FilePath {
		try await buildLibObjects(buildPaths: buildPaths, skipExistingArtifacts: skipExistingArtifacts)
		return try await buildDylib(opensslVersion: opensslVersion, buildPaths: buildPaths, skipExistingArtifacts: skipExistingArtifacts)
	}
	
	private func buildLibObjects(buildPaths: BuildPaths, skipExistingArtifacts: Bool) async throws {
		/* Let’s extract the static libraries’ objects in a folder. We’ll use this
		 * to build the dynamic libraries. */
		let destinationDir = buildPaths.libObjectsDir(for: target)
		guard !skipExistingArtifacts || !Config.fm.fileExists(atPath: destinationDir.string) else {
			Config.logger.info("Skipping static lib extract for target \(target) because \(destinationDir) already exists")
			return
		}
		try Config.fm.ensureDirectoryDeleted(path: destinationDir)
		try Config.fm.ensureDirectory(path: destinationDir)
		
		/* Apparently we *have to* change the CWD (though we should do it through
		 * Process which has an API for that). */
		let previousCwd = Config.fm.currentDirectoryPath
		Config.fm.changeCurrentDirectoryPath(destinationDir.string)
		defer {Config.fm.changeCurrentDirectoryPath(previousCwd)}
		
		for staticLibPath in absoluteStaticLibrariesPaths {
			Config.logger.info("Extracting \(staticLibPath) to \(destinationDir)")
			try await ProcessInvocation("ar", "-x", staticLibPath.string)
				.invokeAndStreamOutput{ line, _, _ in Config.logger.info("ar: fd=\(line.fd): \(line.strLineOrHex())") }
		}
	}
	
	private func buildDylib(opensslVersion: String, buildPaths: BuildPaths, skipExistingArtifacts: Bool) async throws -> FilePath {
		/* Now we build the dynamic libraries. We’ll use those to get FAT dynamic
		 * libraries later. */
		let destination = buildPaths.dylibsDir(for: target).appending(buildPaths.dylibProductNameComponent)
		guard !skipExistingArtifacts || !Config.fm.fileExists(atPath: destination.string) else {
			Config.logger.info("Skipping dynamic lib creation for target \(target) because \(destination) already exists")
			return destination
		}
		try Config.fm.ensureDirectoryDeleted(path: destination.removingLastComponent())
		try Config.fm.ensureDirectory(path: destination.removingLastComponent())
		
		let hasBitcode = try await Self.checkForBitcode(absoluteStaticLibrariesPaths)
		let (sdk, minSdk) = try await Self.getSdkVersions(absoluteStaticLibrariesPaths)
		Config.logger.debug("got sdk \(sdk), min sdk \(minSdk)", metadata: ["target": "\(target)"])
		
		let objectDir = buildPaths.libObjectsDir(for: target)
		let objectFiles = try Config.fm.contentsOfDirectory(atPath: objectDir.string).filter{ $0.hasSuffix(".o") }.map{ objectDir.appending($0) }
		Config.logger.info("Creating dylib at \(destination) from objects in \(objectDir)")
		try await ProcessInvocation("ld", args: objectFiles.map{ $0.string } + (hasBitcode ? ["-bitcode_bundle"] : []) + [
			"-dylib", "-lSystem",
			"-application_extension",
			"-arch", target.arch,
			"-platform_version", target.platformVersionName, minSdk, sdk,
			"-syslibroot", "\(buildPaths.developerDir)/Platforms/\(target.platformLegacyName).platform/Developer/SDKs/\(target.platformLegacyName).sdk",
			"-compatibility_version", Self.normalizedOpenSSLVersion(opensslVersion), /* Not true, but we do not care; the resulting lib will be in a framework which will be embedded in the app and not reused 99.99% of the time, so… */
			"-current_version", Self.normalizedOpenSSLVersion(opensslVersion),
			"-o", destination.string
		]).invokeAndStreamOutput{ line, _, _ in Config.logger.info("ld: fd=\(line.fd): \(line.strLineOrHex())") }
		return destination
	}
	
}


/* Utilities. Not sure it makes a lot of sense to have these functions here, but
 * I don’t really know where to put them. */
extension BuiltTarget {
	
	enum MultipleSdkVersionsResolution {
		
		case error
		case returnMin
		case returnMax
		
	}
	
	/** Inspect Mach-O load commands to get minimum SDK version.
	 
	 Uses `otool`’s output to get this.
	 
	 Depending on the actual minimum SDK version it may look like this for
	 modern SDKs:
	 
	 ```
	 Load command 1
	        cmd LC_BUILD_VERSION
	    cmdsize 24
	   platform 8
	        sdk 13.2   <-- target SDK
	      minos 12.0   <-- minimum SDK
	     ntools 0
	 ```
	 
	 Or like this for older versions, with a platform-dependent tag:
	 
	 ```
	 Load command 1
	       cmd LC_VERSION_MIN_WATCHOS
	   cmdsize 16
	   version 4.0   <-- minimum SDK
	       sdk 6.1   <-- target SDK
	 ``` */
	static func getSdkVersions(_ libs: [FilePath], multipleSdkVersionsResolution: MultipleSdkVersionsResolution = .error) async throws -> (sdk: String, minSdk: String) {
		var sdks = Set<String>()
		var minSdks = Set<String>()
		for lib in libs {
			var error: Error?
			var lastCommand: String?
			try await ProcessInvocation("otool", "-l", lib.string, expectedTerminations: [(0, .exit), (1, .exit) /* otool exits w/ code 1 on broken pipe… */])
				.invokeAndStreamOutput{ lineAndFd, signalEndOfInterestForStream, _ in
					guard error == nil else {return}
					guard let trimmedLine = try? lineAndFd.strLine().trimmingCharacters(in: .whitespaces) else {
						struct NonUtf8LineFromOTool : Error {var line: Data}
						error = NonUtf8LineFromOTool(line: lineAndFd.line)
						signalEndOfInterestForStream()
						return
					}
					
					let lastWord = String(trimmedLine.split(separator: " ").last ?? "")
					switch lineAndFd.fd {
						case .standardOutput:
							switch trimmedLine {
								case let str where str.hasPrefix("Load command "): lastCommand = nil
								case let str where str.hasPrefix("cmd "):          lastCommand = lastWord
								case let str where (
									(str.hasPrefix("minos ")   && lastCommand == "LC_BUILD_VERSION") ||
									(str.hasPrefix("version ") && (lastCommand ?? "").hasPrefix("LC_VERSION_MIN_"))
								):
									minSdks.insert(lastWord)
									guard multipleSdkVersionsResolution != .error || minSdks.count == 1 else {
										Config.logger.error("found multiple min sdks; expected only one: \(minSdks)")
										struct MultipleMinSdkVersionFound : Error {var libs: [FilePath]}
										error = MultipleMinSdkVersionFound(libs: libs)
										signalEndOfInterestForStream()
										return
									}
								case let str where (
									str.hasPrefix("sdk ") && (lastCommand == "LC_BUILD_VERSION" || (lastCommand ?? "").hasPrefix("LC_VERSION_MIN_"))
								):
									guard lastWord != "n/a" else {return}
									sdks.insert(lastWord)
									guard multipleSdkVersionsResolution != .error || sdks.count == 1 else {
										Config.logger.error("found multiple sdks; expected only one: \(sdks)")
										struct MultipleSdkVersionFound : Error {var libs: [FilePath]}
										error = MultipleSdkVersionFound(libs: libs)
										signalEndOfInterestForStream()
										return
									}
									
								default: (/*nop: we simply ignore the line*/)
							}
							
						case .standardError: Config.logger.debug("otool stderr: \(trimmedLine)")
						default:             Config.logger.debug("otool unknown fd: \(trimmedLine)")
					}
				}
			if let e = error {throw e}
		}
		guard !sdks.isEmpty && !minSdks.isEmpty else {
			struct CannotGetSdkOrMinSdk : Error {var libs: [FilePath]}
			throw CannotGetSdkOrMinSdk(libs: libs)
		}
		switch multipleSdkVersionsResolution {
			case .error:
				/* If there were multiple sdk versions found, we’d have returned an
				 * error earlier, so the assert below is valid. */
				assert(sdks.count == 1 && minSdks.count == 1)
				return (sdks.randomElement()!, minSdks.randomElement()!)
				
			case .returnMin:
				return (
					   sdks.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }).first!,
					minSdks.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }).first!
				)
				
			case .returnMax:
				return (
						sdks.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }).last!,
					minSdks.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }).last!
				)
		}
	}
	
	/** If any lib contains bitcode, we return `true`.
	 
	 Something to explore for the detection:
	 
	    otool -v -s __LLVM __bundle path/to/lib
	 
	 Currently we use something along those lines:
	 
	    otool -l path/to/lib | grep __LLVM
	 
	 which is apparently [the Apple-recommended method](https://forums.developer.apple.com/message/7038)
	 (link is dead, it’s from [this stackoverflow comment](https://stackoverflow.com/questions/32808642#comment64079201_33615568)). */
	static func checkForBitcode(_ libs: [FilePath]) async throws -> Bool {
		var foundLLVM = false
		var foundBitcode = false
		for lib in libs {
			var localFoundLLVM = false
			try await ProcessInvocation("otool", "-l", lib.string, expectedTerminations: [(0, .exit), (1, .exit) /* otool exits w/ code 1 on broken pipe… */])
				.invokeAndStreamOutput{ lineAndFd, signalEndOfInterestForStream, _ in
					guard !foundBitcode else {return}
					
					let line = lineAndFd.line
					switch lineAndFd.fd {
						case .standardOutput:
							localFoundLLVM = localFoundLLVM || line.range(of: Data("__LLVM".utf8))    != nil
							foundBitcode   = foundBitcode   || line.range(of: Data("__bitcode".utf8)) != nil
							foundLLVM      = foundLLVM      || localFoundLLVM
							if foundBitcode {
								signalEndOfInterestForStream()
							}
							
						case .standardError: Config.logger.debug("otool stderr: \(lineAndFd.strLineOrHex())")
						default:             Config.logger.debug("otool unknown fd: \(lineAndFd.strLineOrHex())")
					}
				}
			if localFoundLLVM && !foundBitcode {
				Config.logger.warning("__LLVM found in \(lib.string), but __bitcode was not (if lib is dynamic this is expected)")
			}
			if foundBitcode {
				break
			}
		}
		return foundBitcode || foundLLVM
	}
	
	static func normalizedOpenSSLVersion(_ version: String) -> String {
		let version = String(version.split(separator: "-").first ?? "") /* We remove all beta reference (example of version with beta: 3.0.0-beta1) */
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
		return version
	}
	
}
