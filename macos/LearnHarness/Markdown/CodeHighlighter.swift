import AppKit
import Highlightr
import SwiftUI

/// Highlightr (highlight.js in JavaScriptCore) behind a cache. Light and
/// dark use their own themes; an unknown language falls back to plain.
@MainActor
enum CodeHighlighter {
	private struct Key: Hashable {
		var source: String
		var language: String?
		var dark: Bool
	}

	private static var cache: [Key: AttributedString] = [:]
	private static let light: Highlightr? = make("xcode")
	private static let dark: Highlightr? = make("atom-one-dark")

	private static func make(_ theme: String) -> Highlightr? {
		let h = Highlightr()
		h?.setTheme(to: theme)
		h?.theme.setCodeFont(.monospacedSystemFont(ofSize: 12, weight: .regular))
		return h
	}

	static func highlight(_ source: String, language: String?, dark isDark: Bool) -> AttributedString {
		let key = Key(source: source, language: language, dark: isDark)
		if let hit = cache[key] { return hit }
		let engine = isDark ? dark : light
		var out = AttributedString(source)
		if let engine, let lang = language?.lowercased(), engine.supportedLanguages().contains(lang),
		   let highlighted = engine.highlight(source, as: lang, fastRender: true)
		{
			let ns = NSMutableAttributedString(attributedString: highlighted)
			// The theme's own background stays out — the block draws its fill.
			ns.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: ns.length))
			if let converted = try? AttributedString(ns, including: \.appKit) { out = converted }
		}
		if cache.count > 500 { cache.removeAll() }
		cache[key] = out
		return out
	}
}
