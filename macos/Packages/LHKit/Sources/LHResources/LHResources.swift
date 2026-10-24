import Foundation

/// Bundled read-only resources (models.json, mermaid 11.17.0, MathJax 3.2.2; prompts
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

	/// MathJax 3.2.2 bundled for JavaScriptCore (macos/scripts/build-mathjax.sh):
	/// defines `lhTex2Svg(tex, display)`.
	public static var mathJaxJS: String {
		get throws {
			guard let url = Bundle.module.url(forResource: "mathjax-svg", withExtension: "js") else {
				throw CocoaError(.fileNoSuchFile)
			}
			return try String(contentsOf: url, encoding: .utf8)
		}
	}

	/// A bundled prompt segment by its segment path ("system-prompt.md",
	/// "teacher/05-method.md", …) — verbatim copies of src/agent/prompts.
	public static func promptSegment(_ path: String) -> String? {
		guard let dir = Bundle.module.url(forResource: "prompts", withExtension: nil) else { return nil }
		return try? String(contentsOf: dir.appending(path: path), encoding: .utf8)
	}

	/// The fragment file names (sorted) under one prompts directory.
	public static func promptFragments(_ directory: String) -> [String] {
		guard let dir = Bundle.module.url(forResource: "prompts", withExtension: nil) else { return [] }
		let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: directory).path)) ?? []
		return names.sorted()
	}

	/// prompt-gates.json.
	public static var promptGatesJSON: Data {
		get throws {
			guard let url = Bundle.module.url(forResource: "prompt-gates", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
			return try Data(contentsOf: url)
		}
	}
}
