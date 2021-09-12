import Foundation
import System

import Logging
import SystemPackage
import XcodeTools



struct UnbuiltTarget {
	
	var target: Target
	var tarball: Tarball
	var buildPaths: BuildPaths
	
	var sdkVersion: String?
	var minSDKVersion: String?
	var opensslVersion: String
	
	var disableBitcode: Bool
	
	var skipExistingArtifacts: Bool
	
	func buildTarget() async throws -> BuiltTarget {
		let sourceDir = buildPaths.sourceDir(for: target)
		let installDir = buildPaths.installDir(for: target)
		try await extractTarballBuildAndInstallIfNeeded(installDir: installDir, sourceDir: sourceDir)
		
		let (headers, staticLibs) = try retrieveArtifacts()
		return BuiltTarget(target: target, sourceFolder: sourceDir, installFolder: installDir, staticLibraries: staticLibs, dynamicLibraries: [], headers: headers, resources: [])
	}
	
	private func extractTarballBuildAndInstallIfNeeded(installDir: FilePath, sourceDir: FilePath) async throws {
		let opensslConfigDir = try buildPaths.opensslConfigsDir(for: opensslVersion)
		
		guard !skipExistingArtifacts || !Config.fm.fileExists(atPath: installDir.string) else {
			Config.logger.info("Skipping building of target \(target) because \(installDir) exists")
			return
		}
		
		/* ********* SOURCE EXTRACTION ********* */
		
		/* Extract tarball in source directory. If the tarball was already there,
		 * tar will overwrite existing files (but will not remove additional
		 * files). */
		let extractedTarballDir = try await tarball.extract(in: sourceDir)
		
		/* ********* BUILD & INSTALL ********* */
		
		Config.logger.info("Building for target \(target)")
		
		/* Apparently we *have to* change the CWD (though we should do it through
		 * Process which has an API for that). */
		let previousCwd = Config.fm.currentDirectoryPath
		Config.fm.changeCurrentDirectoryPath(extractedTarballDir.string)
		defer {Config.fm.changeCurrentDirectoryPath(previousCwd)}
		
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
		/* We should change the env via the Process APIs so that only the children
		 * has a different env, but our conveniences don’t know these APIs. */
		setenv("CROSS_COMPILE",              buildPaths.developerDir.appending("Toolchains/XcodeDefault.xctoolchain/usr/bin").string + "/", 1)
		setenv("OPENSSLBUILD_SDKs_LOCATION", buildPaths.developerDir.appending("Platforms").appending(platformPathComponent).appending("Developer").string, 1)
		setenv("OPENSSLBUILD_SDK",           sdkPathComponent.string, 1)
		setenv("OPENSSL_LOCAL_CONFIG_DIR",   opensslConfigDir.string, 1)
		if let sdkVersion = sdkVersion {  setenv("OPENSSLBUILD_SDKVERSION", sdkVersion, 1)}
		else                           {unsetenv("OPENSSLBUILD_SDKVERSION")}
		if let minSDKVersion = minSDKVersion {  setenv("OPENSSLBUILD_MIN_SDKVERSION", minSDKVersion, 1)}
		else                                 {unsetenv("OPENSSLBUILD_MIN_SDKVERSION")}
		if disableBitcode {  setenv("OPENSSLBUILD_DISABLE_BITCODE", "true", 1)}
		else              {unsetenv("OPENSSLBUILD_DISABLE_BITCODE")}
		let configArgs = [
			target.openSSLConfigName,
			"--prefix=\(installDir.string)",
			"no-async",
			"no-shared",
			"no-tests"
		] + (target.arch.hasSuffix("64") ? ["enable-ec_nistp_64_gcc_128"] : [])
		try await ProcessInvocation(SystemPackage.FilePath(extractedTarballDir.appending("Configure").string), args: configArgs)
			.invokeAndStreamOutput{ line, _, _ in Config.logger.debug("Configure: fd=\(line.fd.rawValue): \(line.strLineOrHex())") }
		
		/* *** Build *** */
		try await ProcessInvocation("make", args: multicoreMakeOption)
			.invokeAndStreamOutput{ line, _, _ in Config.logger.debug("make: fd=\(line.fd.rawValue): \(line.strLineOrHex())") }
		
		/* *** Install *** */
		try await ProcessInvocation("make", args: ["install_sw"] + multicoreMakeOption)
			.invokeAndStreamOutput{ line, _, _ in Config.logger.debug("make install_sw: fd=\(line.fd.rawValue): \(line.strLineOrHex())") }
	}
	
	private func retrieveArtifacts() throws -> (headers: [FilePath], staticLibs: [FilePath]) {
		let installDir = buildPaths.installDir(for: target)
		let exclusions = try [
			NSRegularExpression(pattern: #"^\.DS_Store$"#, options: []),
			NSRegularExpression(pattern: #"/\.DS_Store$"#, options: [])
		]
		
		var headers = [FilePath]()
		var staticLibs = [FilePath]()
		try Config.fm.iterateFiles(in: installDir, exclude: exclusions, handler: { fullPath, relativePath, isDir in
			func checkFileLocation(expectedLocation: FilePath, fileType: String) {
				if !relativePath.starts(with: expectedLocation) {
					Config.logger.warning("found \(fileType) at unexpected location: \(relativePath)", metadata: ["target": "\(target)", "path_root": "\(installDir)"])
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
					Config.logger.warning("found unknown file: \(relativePath)", metadata: ["target": "\(target)", "path_root": "\(installDir)"])
			}
			return true
		})
		return (headers, staticLibs)
	}
	
	private static var numberOfCores: Int? = {
		guard MemoryLayout<Int32>.size <= MemoryLayout<Int>.size else {
			Config.logger.notice("Int32 is bigger than Int (\(MemoryLayout<Int32>.size) > \(MemoryLayout<Int>.size)). Cannot return the number of cores.")
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
