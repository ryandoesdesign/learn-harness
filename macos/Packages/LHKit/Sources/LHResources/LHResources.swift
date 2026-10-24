import Foundation

/// Bundled read-only resources (models.json, mermaid 11.17.0; prompts
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

	/// mermaid 11.17.0's `mermaid.min.js`, copied verbatim from the TS app's node_modules.
	public static var mermaidJS: String {
		get throws {
			guard let url = Bundle.module.url(forResource: "mermaid.min", withExtension: "js") else {
				throw CocoaError(.fileNoSuchFile)
			}
			return try String(contentsOf: url, encoding: .utf8)
		}
	}
}
