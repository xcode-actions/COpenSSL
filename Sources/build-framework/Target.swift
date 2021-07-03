import Foundation

import ArgumentParser



struct Target : Hashable, ExpressibleByArgument, CustomStringConvertible {
	
	var sdk: String
	var platform: String
	var arch: String
	
	init(sdk: String, platform: String, arch: String) {
		self.sdk = sdk
		self.platform = platform
		self.arch = arch
	}
	
	init?(argument: String) {
		let components = argument.split(separator: "-", omittingEmptySubsequences: false)
		guard components.count == 3 else {return nil}
		
		self.sdk      = String(components[0])
		self.platform = String(components[1])
		self.arch     = String(components[2])
	}
	
	/** The name in the config file we provide to OpenSSL */
	var openSSLConfigName: String {
		/* We assume the sdk, platform and arch are valid (do not contain dashes). */
		return [sdk, platform, arch].joined(separator: "-")
	}
	
	var description: String {
		return openSSLConfigName
	}
	
	var platformLegacyName: String {
		switch platform {
			case "macOS":             return "MacOSX"
			case "iOS":               return "iPhoneOS"
			case "iOS_Simulator":     return "iPhoneSimulator"
			case "tvOS":              return "AppleTVOS"
			case "tvOS_Simulator":    return "AppleTVSimulator"
			case "watchOS":           return "WatchOS"
			case "watchOS_Simulator": return "WatchSimulator"
			default: return platform.replacingOccurrences(of: "_", with: " ")
		}
	}
	
}
