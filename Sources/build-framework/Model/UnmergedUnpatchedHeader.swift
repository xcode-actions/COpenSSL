import Foundation



struct UnmergedUnpatchedHeader {
	
	var headersAndArchs: [(header: FilePath, arch: String)]
	var patches: [(String) -> String]
	var skipExistingArtifacts: Bool
	
	func patchAndMergeHeaders(at destPath: FilePath) throws {
		guard headersAndArchs.count > 0 else {
			Config.logger.warning("Asked to create a merged header at path \(destPath), but no headers given.")
			return
		}
		guard !skipExistingArtifacts || !Config.fm.fileExists(atPath: destPath.string) else {
			Config.logger.info("Skipping creation of \(destPath) because it already exists")
			return
		}
		try Config.fm.ensureDirectory(path: destPath.removingLastComponent())
		try Config.fm.ensureFileDeleted(path: destPath)
		
		Config.logger.info("Creating merged header \(destPath) from \(headersAndArchs.count) headers(s)")
		/* First, do we need to merge the headers or are they all the same? */
		let needsMerge = try (Set(headersAndArchs.map{ try Data(contentsOf: $0.header.url) }).count > 1)
		
		if !needsMerge {
			/* We simply copy any header to the destination */
			if patches.isEmpty {
				Config.logger.debug("  -> No need for merge nor patch; copying header directly")
				try Config.fm.copyItem(at: headersAndArchs.first!.header.url, to: destPath.url)
			} else {
				Config.logger.debug("  -> No need for merge; simply patching header")
				let str = try String(contentsOf: headersAndArchs.first!.header.url)
				let patchedStr = patches.reduce(str, { $1($0) })
				try patchedStr.write(to: destPath.url, atomically: true, encoding: .utf8)
			}
		} else {
			Config.logger.debug("  -> Merge is needed")
			var result = """
				/* Merged file from multiple archs */
				#include <TargetConditionals.h>
				
				
				"""
			var first = true
			for (header, arch) in headersAndArchs {
				defer {first = false}
				result += (first ? "#if " : "#elif ") + "__is_target_arch(\(arch))\n"
				result += try patches.reduce(String(contentsOf: header.url), { $1($0) })  + "\n"
			}
			result += "#endif\n"
			try result.write(to: destPath.url, atomically: true, encoding: .utf8)
		}
	}
	
}
