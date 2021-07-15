import Foundation

import Logging



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
