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
struct BuildOpenLdap : ParsableCommand {
	
	@Option(help: "Everything build-openldap will do will be in this folder. The folder will be created if it does not exist.")
	var workdir = "./openldap-workdir"
	
	@Option(help: "The base URL from which to download LDAP. Everything between double curly braces “{{}}” will be replaced by the LDAP version to build.")
	var ldapBaseURL = "https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-{{ version }}.tgz"
	
	@Option
	var ldapVersion = "2.5.5"
	
	/* For 2.5.5, value is 74ecefda2afc0e054d2c7dc29166be6587fa9de7a4087a80183bc9c719dbf6b3 */
	@Option(help: "The shasum-256 expected for the tarball. If not set, the integrity of the archive will not be verified.")
	var expectedTarballShasum: String?
	
	@Option
	var targets = [
		Target("macOS" "macOS"),
				(sdk: "iOS", platform: "iOS"),
				(sdk: "iOS", platform: "iOS Simulator"),
				(sdk: "iOS", platform: "macOS"),
				(sdk: "tvOS", platform: "tvOS"),
				(sdk: "tvOS", platform: "tvOS Simulator"),
				(sdk: "watchOS", platform: "watchOS"),
				(sdk: "watchOS", platform: "watchOS Simulator
		"macos64-x86_64", "macos64-arm64",
		"ios-sim-cross-x86_64", "ios-sim-cross-arm64", "ios64-cross-arm64", "ios64-cross-arm64e",
		"mac-catalyst-x86_64", "mac-catalyst-arm64",
		"watchos-cross-armv7k", "watchos-cross-arm64_32", "watchos-sim-cross-x86_64", "watchos-sim-cross-i386", "watchos-sim-cross-arm64",
		"tvos-sim-cross-x86_64", "tvos64-cross-arm64"
	]
	
	@Option(name: .customLong("macos-min-sdk-version"))
	var macOSMinSDKVersion = "10.15"
	
	@Option(name: .customLong("ios-min-sdk-version"))
	var iOSMinSDKVersion = "12.0"
	
	@Option
	var catalystMinSDKVersion="10.15"
	
	@Option(name: .customLong("watchos-min-sdk-version"))
	var watchOSMinSDKVersion="4.0"
	
	@Option(name: .customLong("tvos-min-sdk-version"))
	var tvOSMinSDKVersion="12.0"
	
	func run() async throws {
		LoggingSystem.bootstrap{ _ in CLTLogger() }
		let logger = { () -> Logger in
			var ret = Logger(label: "me.frizlab.build-openldap")
			ret.logLevel = .debug
			return ret
		}()
		
		let fm = FileManager.default
		
		var isDir = ObjCBool(false)
		if !fm.fileExists(atPath: workdir, isDirectory: &isDir) {
			try fm.createDirectory(at: URL(fileURLWithPath: workdir), withIntermediateDirectories: true, attributes: nil)
		} else {
			guard isDir.boolValue else {
				struct WorkDirIsNotDir : Error {}
				throw WorkDirIsNotDir()
			}
		}
		
		fm.changeCurrentDirectoryPath(workdir)
		
		let tarballStringURL = ldapBaseURL.applying(xibLocInfo: Str2StrXibLocInfo(simpleSourceTypeReplacements: [OneWordTokens(leftToken: "{{", rightToken: "}}"): { _ in ldapVersion }], identityReplacement: { $0 })!)
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
			try fm.removeItem(at: localTarballURL)
			try fm.moveItem(at: tmpFileURL, to: localTarballURL)
			logger.info("Tarball downloaded")
		}
		
//		let args = [
//			"--prefix=\(scriptDir)/build/version_TODO",
//			"--enable-accesslog",
//			"--enable-auditlog",
//			"--enable-constraint",
//			"--enable-dds",
//			"--enable-deref",
//			"--enable-dyngroup",
//			"--enable-dynlist",
//			"--enable-memberof",
//			"--enable-ppolicy",
//			"--enable-proxycache",
//			"--enable-refint",
//			"--enable-retcode",
//			"--enable-seqmod",
//			"--enable-translucent",
//			"--enable-unique",
//			"--enable-valsort"
//		]
//		try Process.spawnAndStream("./configure", args: args, outputHandler: { _,_ in })
//		try Process.spawnAndStream("/usr/bin/make", args: ["install"], outputHandler: { _,_ in })
	}
	
	private func checkChecksum(file: URL, expectedChecksum: String?) throws -> Bool {
		guard let expectedChecksum = expectedChecksum else {
			return true
		}
		
		let fileContents = try Data(contentsOf: file)
		return SHA256.hash(data: fileContents).reduce("", { $0 + String(format: "%02x", $1) }) == expectedChecksum.lowercased()
	}
	
	private func buildLDAP(sourceTarball: URL, platform: String, sdkVersion: String, arch: String) throws {
		
	}
	
}
