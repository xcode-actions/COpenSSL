import Foundation



extension FileManager {
	
	func ensureDirectory(path: String) throws {
		var isDir = ObjCBool(false)
		if !fileExists(atPath: path, isDirectory: &isDir) {
			try createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true, attributes: nil)
		} else {
			guard isDir.boolValue else {
				struct ExpectedDir : Error {var path: String}
				throw ExpectedDir(path: path)
			}
		}
	}
	
	func ensureDirectoryDeleted(path: String) throws {
		var isDir = ObjCBool(false)
		if fileExists(atPath: path, isDirectory: &isDir) {
			guard isDir.boolValue else {
				struct ExpectedDir : Error {var path: String}
				throw ExpectedDir(path: path)
			}
			try removeItem(at: URL(fileURLWithPath: path))
		}
	}
	
	func ensureFileDeleted(path: String) throws {
		var isDir = ObjCBool(false)
		if fileExists(atPath: path, isDirectory: &isDir) {
			guard !isDir.boolValue else {
				struct ExpectedFile : Error {var path: String}
				throw ExpectedFile(path: path)
			}
			try removeItem(at: URL(fileURLWithPath: path))
		}
	}
	
}
