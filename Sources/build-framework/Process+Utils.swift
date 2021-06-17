import Foundation

import Logging
import SignalHandling
import SystemPackage
import XcodeTools



extension Process {
	
	public static func logProcessOutputFactory(logger: Logger) -> (String, FileDescriptor) -> Void {
		return { line, fd in
			let trimmedLine = line.trimmingCharacters(in: .newlines)
			switch fd {
				case .standardOutput: logger.trace("stdout: \(trimmedLine)")
				case .standardError:  logger.trace("stderr: \(trimmedLine)")
				default:              logger.trace("unknown fd: \(trimmedLine)")
			}
		}
	}
	
	public static func spawnAndStreamEnsuringSuccess(
		_ executable: String, args: [String] = [],
		stdin: FileDescriptor? = FileDescriptor.standardInput,
		stdoutRedirect: RedirectMode = RedirectMode.capture,
		stderrRedirect: RedirectMode = RedirectMode.capture,
		fileDescriptorsToSend: [FileDescriptor /* Value in parent */: FileDescriptor /* Value in child */] = [:],
		additionalOutputFileDescriptors: Set<FileDescriptor> = [],
		signalsToForward: Set<Signal> = Signal.toForwardToSubprocesses,
		outputHandler: @escaping (_ line: String, _ sourceFd: FileDescriptor) -> Void
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
		stdin: FileDescriptor? = FileDescriptor.standardInput,
		signalsToForward: Set<Signal> = Signal.toForwardToSubprocesses
	) throws -> String {
		var stdout = ""
		let outputHandler: (String, FileDescriptor) -> Void = { line, fd in
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
