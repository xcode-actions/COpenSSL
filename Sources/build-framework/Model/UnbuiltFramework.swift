import Foundation
import System



struct UnbuiltFramework {
	
	var libPath: FilePath
	var headers: [FilePath]
	var modules: [FilePath]
	/** The framework resources, except for the Info.plist */
	var resources: [FilePath]
	
	let skipExistingArtifacts: Bool
	
}
