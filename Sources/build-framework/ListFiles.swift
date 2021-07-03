import Foundation



enum ListFiles {
	
	enum Err : Error {
		
		case invalidArgument
		case cannotGetIsDirectory
		case cannotCreateEnumerator
		case enumeratorReturnedANonURLObject
		case enumeratorReturnedAnURLOutsideOfRootFolder
		
	}
	
	/**
	 Call the handler with the files. If the handler returns false, the iteration
	 is stopped. */
	static func iterateFiles(in folder: URL, exclude: [NSRegularExpression], handler: (URL, String, Bool) -> Bool) throws {
		guard folder.isFileURL else {
			throw Err.invalidArgument
		}
		
		let rootFolderPath: String
		do {
			let p = folder.absoluteURL.path
			rootFolderPath = p + (p.hasSuffix("/") ? "" : "/")
		}
		
		let fm = FileManager.default
		guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else {
			throw Err.cannotCreateEnumerator
		}
		
		for nextObject in enumerator {
			guard let url = nextObject as? URL else {
				throw Err.enumeratorReturnedANonURLObject
			}
			let fullPath = url.absoluteURL.path
			guard fullPath.hasPrefix(rootFolderPath) else {
				throw Err.enumeratorReturnedAnURLOutsideOfRootFolder
			}
			let path = String(fullPath.dropFirst(rootFolderPath.count))
			guard !exclude.contains(where: { $0.rangeOfFirstMatch(in: path, range: NSRange(path.startIndex..<path.endIndex, in: path)).location != NSNotFound }) else {
				continue
			}
			guard let isDir = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
				throw Err.cannotGetIsDirectory
			}
			guard handler(url, path, isDir) else {return}
		}
	}
	
}
