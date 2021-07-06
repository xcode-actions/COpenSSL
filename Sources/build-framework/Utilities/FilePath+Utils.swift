import Foundation

import SystemPackage



@available(macOS 12.0, *) // TODO: Remove when v12 exists in Package.swift
extension FilePath {
	
	var url: URL {
		return URL(fileURLWithPath: string)
	}
	
}
