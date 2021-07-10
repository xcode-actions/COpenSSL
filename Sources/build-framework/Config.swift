import Foundation

import Logging



@available(macOS 12.0, *) // TODO: Remove when v12 exists in Package.swift
enum Config {
	
	@TaskLocal
	static var fm: FileManager = .default
	
	@TaskLocal
	static var logger: Logger = { () -> Logger in
		var ret = Logger(label: "com.xcode-actions.build-openssl")
		ret.logLevel = .debug
		return ret
	}()
	
}
