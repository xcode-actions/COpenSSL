import Foundation
import System

import Logging
import SignalHandling
import SystemPackage
import XcodeTools



public typealias FileDescriptor = System.FileDescriptor

extension Process {
	
	public static func logProcessOutputFactory(logLevel: Logger.Level = .debug) -> (String, SystemPackage.FileDescriptor) -> Void {
		return { line, fd in
			let trimmedLine = line.trimmingCharacters(in: .newlines)
			switch fd {
				case .standardOutput: Config.logger.log(level: logLevel, "stdout: \(trimmedLine)")
				case .standardError:  Config.logger.log(level: logLevel, "stderr: \(trimmedLine)")
				default:              Config.logger.log(level: logLevel, "unknown fd: \(trimmedLine)")
			}
		}
	}
	
	public static func spawnAndStreamEnsuringSuccess(
		_ executable: String, args: [String] = [],
		stdin: SystemPackage.FileDescriptor? = .standardInput,
		stdoutRedirect: RedirectMode = .capture,
		stderrRedirect: RedirectMode = .capture,
		fileDescriptorsToSend: [SystemPackage.FileDescriptor /* Value in parent */: SystemPackage.FileDescriptor /* Value in child */] = [:],
		additionalOutputFileDescriptors: Set<SystemPackage.FileDescriptor> = [],
		signalsToForward: Set<Signal> = Signal.toForwardToSubprocesses,
		outputHandler: @escaping (_ line: String, _ sourceFd: SystemPackage.FileDescriptor) -> Void
	) throws {
		let (terminationStatus, terminationReason) = try spawnAndStream(
			executable, args: args,
			stdin: stdin, stdoutRedirect: stdoutRedirect, stderrRedirect: stderrRedirect,
			fileDescriptorsToSend: fileDescriptorsToSend, additionalOutputFileDescriptors: additionalOutputFileDescriptors,
			signalsToForward: signalsToForward,
			outputHandler: outputHandler
		)
		guard terminationStatus == 0, terminationReason == .exit else {
			struct ProcessFailed : Error {var executable: String; var args: [String]}
			throw ProcessFailed(executable: executable, args: args)
		}
	}
	
	public static func spawnAndGetOutput(
		_ executable: String, args: [String] = [],
		stdin: SystemPackage.FileDescriptor? = .standardInput,
		signalsToForward: Set<Signal> = Signal.toForwardToSubprocesses
	) throws -> String {
		var stdout = ""
		let outputHandler: (String, SystemPackage.FileDescriptor) -> Void = { line, fd in
			assert(fd == .standardOutput)
			stdout += line
		}
		let (terminationStatus, terminationReason) = try spawnAndStream(
			executable, args: args,
			stdin: stdin, stdoutRedirect: .capture, stderrRedirect: .capture,
			signalsToForward: signalsToForward,
			outputHandler: outputHandler
		)
		guard terminationStatus == 0, terminationReason == .exit else {
			struct ProcessFailed : Error {var executable: String; var args: [String]}
			throw ProcessFailed(executable: executable, args: args)
		}
		return stdout
	}
	
}
