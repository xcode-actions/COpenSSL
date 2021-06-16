import Foundation

import ArgumentParser



struct Target : ExpressibleByArgument {
	
	var sdk: String
	var platform: String
	var arch: String
	
}
