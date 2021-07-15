import Foundation
import System



extension FilePath {
	
	var url: URL {
		return URL(fileURLWithPath: string)
	}
	
}
