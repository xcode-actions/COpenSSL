import Foundation
import System

import Logging



@available(macOS 12.0, *) // TODO: Remove when v12 exists in Package.swift
struct UnbuiltTarget {
	
	let target: Target
	let tarball: Tarball
	let buildPaths: BuildPaths
	
	let sdkVersion: String?
	let minSDKVersion: String?
	let opensslVersion: String
	
	let skipExistingArtifacts: Bool
	
	func buildTarget(fileManager fm: FileManager, logger: Logger) throws -> BuiltTarget {
		let sourceDir = buildPaths.sourceDir(for: target)
		let installDir = buildPaths.installDir(for: target)
		try extractTarballBuildAndInstallIfNeeded(installDir: installDir, sourceDir: sourceDir, fileManager: fm, logger: logger)
		
		let (headers, staticLibs) = try retrieveArtifacts(fileManager: fm, logger: logger)
		return BuiltTarget(target: target, sourceFolder: sourceDir, installFolder: installDir, staticLibraries: staticLibs, dynamicLibraries: [], headers: headers, resources: [])
	}
	
	private func extractTarballBuildAndInstallIfNeeded(installDir: FilePath, sourceDir: FilePath, fileManager fm: FileManager, logger: Logger) throws {
		let opensslConfigDir = try buildPaths.opensslConfigsDir(for: opensslVersion, fileManager: fm)
		
		guard !skipExistingArtifacts || !fm.fileExists(atPath: installDir.string) else {
			logger.info("Skipping building of target \(target) because \(installDir) exists")
			return
		}
		
		/* ********* SOURCE EXTRACTION ********* */
		
		/* Extract tarball in source directory. If the tarball was already there,
		 * tar will overwrite existing files (but will not remove additional
		 * files). */
		let extractedTarballDir = try tarball.extract(in: sourceDir, fileManager: fm, logger: logger)
		
		/* ********* BUILD & INSTALL ********* */
		
		logger.info("Building for target \(target)")
		
		/* Apparently we *have to* change the CWD (though we should do it through
		 * Process which has an API for that). */
		let previousCwd = fm.currentDirectoryPath
		fm.changeCurrentDirectoryPath(extractedTarballDir.string)
		defer {fm.changeCurrentDirectoryPath(previousCwd)}
		
		/* Prepare -j option for make */
		let multicoreMakeOption = Self.numberOfCores.flatMap{ ["-j", "\($0)"] } ?? []
		
		/* *** Configure *** */
		guard
			let platformPathComponent = FilePath.Component(target.platformLegacyName + ".platform"),
			let sdkPathComponent = FilePath.Component(target.platformLegacyName + (sdkVersion ?? "") + ".sdk")
		else {
			struct InternalError : Error {}
			throw InternalError()
		}
		setenv("CROSS_COMPILE",              buildPaths.developerDir.appending("Toolchains/XcodeDefault.xctoolchain/usr/bin/").string, 1)
		setenv("OPENSSLBUILD_SDKs_LOCATION", buildPaths.developerDir.appending("Platforms").appending(platformPathComponent).appending("Developer").string, 1)
		setenv("OPENSSLBUILD_SDK",           sdkPathComponent.string, 1)
		setenv("OPENSSL_LOCAL_CONFIG_DIR",   opensslConfigDir.string, 1)
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
			target.openSSLConfigName,
			"--prefix=\(installDir.string)",
			"no-async",
			"no-shared",
			"no-tests"
		] + (target.arch.hasSuffix("64") ? ["enable-ec_nistp_64_gcc_128"] : [])
		try Process.spawnAndStreamEnsuringSuccess(sourceDir.appending("Configure").string, args: configArgs, outputHandler: Process.logProcessOutputFactory(logger: logger))
		
		/* *** Build *** */
		try Process.spawnAndStreamEnsuringSuccess("/usr/bin/xcrun", args: ["make"] + multicoreMakeOption, outputHandler: Process.logProcessOutputFactory(logger: logger))
		
		/* *** Install *** */
		try Process.spawnAndStreamEnsuringSuccess("/usr/bin/xcrun", args: ["make", "install_sw"] + multicoreMakeOption, outputHandler: Process.logProcessOutputFactory(logger: logger))
	}
	
	private func retrieveArtifacts(fileManager fm: FileManager, logger: Logger) throws -> (headers: [FilePath], staticLibs: [FilePath]) {
		let installDir = buildPaths.installDir(for: target)
		let exclusions = try [
			NSRegularExpression(pattern: #"^\.DS_Store$"#, options: []),
			NSRegularExpression(pattern: #"/\.DS_Store$"#, options: [])
		]
		
		var headers = [FilePath]()
		var staticLibs = [FilePath]()
		try fm.iterateFiles(in: installDir, exclude: exclusions, handler: { fullPath, relativePath, isDir in
			func checkFileLocation(expectedLocation: FilePath, fileType: String) {
				if !relativePath.starts(with: expectedLocation) {
					logger.warning("found \(fileType) at unexpected location: \(relativePath)", metadata: ["target": "\(target)", "path_root": "\(installDir)"])
				}
			}
			
			switch (isDir, fullPath.extension) {
				case (true, _): (/*nop*/)
					
				case (false, "a"):
					/* We found a static lib. Let’s check its location and add it. */
					checkFileLocation(expectedLocation: "lib", fileType: "lib")
					staticLibs.append(relativePath)
					
				case (false, "h"):
					/* We found a header lib. Let’s check its location and add it. */
					checkFileLocation(expectedLocation: "include/openssl", fileType: "header")
					headers.append(relativePath)
					
				case (false, nil):
					/* Binary. We don’t care about binaries. But let’s check it is
					 * at an expected location. */
					checkFileLocation(expectedLocation: "bin", fileType: "binary")
					
				case (false, "pc"):
					/* pkgconfig file. We don’t care about those. But let’s check
					 * this one is at an expected location. */
					checkFileLocation(expectedLocation: "lib/pkgconfig", fileType: "pc file")
					
				case (false, _):
					logger.warning("found unknown file: \(relativePath)", metadata: ["target": "\(target)", "path_root": "\(installDir)"])
			}
			return true
		})
		return (headers, staticLibs)
	}
	
	private static var numberOfCores: Int? = {
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
	
}
