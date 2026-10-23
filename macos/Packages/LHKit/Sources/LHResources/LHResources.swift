import Foundation

/// Bundled read-only resources (models.json; prompts, KaTeX and mermaid
/// arrive with the milestones that use them).
public enum LHResources {
	public static var modelsJSON: Data {
		get throws {
			guard let url = Bundle.module.url(forResource: "models", withExtension: "json") else {
				throw CocoaError(.fileNoSuchFile)
			}
			return try Data(contentsOf: url)
		}
	}
}
