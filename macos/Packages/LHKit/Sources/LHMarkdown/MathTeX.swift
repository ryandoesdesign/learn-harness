import Foundation
import JavaScriptCore
import LHResources

// The math engine (docs/native-macos-m4.md, implementation notes): MathJax
// 3.2.2 in JavaScriptCore turns TeX into a standalone SVG — glyphs as
// paths, no fonts, no DOM, no WebView — which AppKit draws natively, so
// math stays vector-sharp at any size. Synchronous: ~1–3 ms per expression
// after a one-time ~50 ms load.

/// One typeset expression. Geometry is in em (MathJax's 1000 units per em):
/// multiply by the font size for points.
public struct MathSVG: Sendable, Hashable {
	public var svg: String
	public var widthEm: Double
	public var heightEm: Double
	/// How far the expression reaches below the baseline.
	public var depthEm: Double
}

public enum MathRenderError: Error, Sendable, Hashable, CustomStringConvertible {
	case tex(String)
	case engine(String)
	public var description: String {
		switch self {
		case .tex(let m): m
		case .engine(let m): "Math engine unavailable: \(m)"
		}
	}
}

/// KaTeX-isms the TS pipeline emits that MathJax spells differently:
/// transformMathDelimiters' escaped-dollar form `\text{\textdollar}` →
/// `\$`, which MathJax accepts in math AND text mode (the transform also
/// wraps dollars already inside `\text{…}`, and MathJax rejects nested
/// `\text`).
public func normalizedTeX(_ tex: String) -> String {
	tex.replacingOccurrences(of: "\\text{\\textdollar}", with: "\\$")
		.replacingOccurrences(of: "\\textdollar", with: "\\$")
}

/// The shared engine. JSContext is single-threaded; a lock serializes calls,
/// and results are cached by (TeX, display).
public final class MathJax: @unchecked Sendable {
	public static let shared = MathJax()

	private let lock = NSLock()
	private var context: JSContext?
	private var convert: JSValue?
	private var loadError: String?
	private var cache: [Key: Result<MathSVG, MathRenderError>] = [:]

	private struct Key: Hashable {
		var tex: String
		var display: Bool
	}

	private init() {}

	public func render(_ tex: String, display: Bool) -> Result<MathSVG, MathRenderError> {
		lock.lock()
		defer { lock.unlock() }
		let key = Key(tex: tex, display: display)
		if let hit = cache[key] { return hit }
		let result = typeset(normalizedTeX(tex), display: display)
		if cache.count > 5000 { cache.removeAll() }
		cache[key] = result
		return result
	}

	private func load() {
		guard context == nil, loadError == nil else { return }
		guard let ctx = JSContext() else { loadError = "No JavaScript context"; return }
		var thrown: String?
		ctx.exceptionHandler = { _, e in thrown = e?.toString() }
		do {
			ctx.evaluateScript(try LHResources.mathJaxJS)
		} catch {
			loadError = "\(error)"
			return
		}
		if let thrown { loadError = thrown; return }
		guard let fn = ctx.objectForKeyedSubscript("lhTex2Svg"), !fn.isUndefined else { loadError = "lhTex2Svg missing"; return }
		context = ctx
		convert = fn
	}

	private func typeset(_ tex: String, display: Bool) -> Result<MathSVG, MathRenderError> {
		load()
		guard let convert else { return .failure(.engine(loadError ?? "not loaded")) }
		guard let r = convert.call(withArguments: [tex, display]) else { return .failure(.engine("no result")) }
		if let err = r.forProperty("error"), !err.isNull, !err.isUndefined { return .failure(.tex(err.toString())) }
		guard let svg = r.forProperty("svg")?.toString(), let geometry = svgGeometry(svg) else { return .failure(.engine("no svg")) }
		return .success(MathSVG(svg: svg, widthEm: geometry.width, heightEm: geometry.height, depthEm: geometry.depth))
	}
}

/// The root viewBox `minX minY w h` (1000 units per em): the baseline is
/// y = 0, so the depth below it is minY + h.
func svgGeometry(_ svg: String) -> (width: Double, height: Double, depth: Double)? {
	guard let m = svg.firstMatch(of: /<svg\b[^>]*?\bviewBox="([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+)"/),
	      let minY = Double(m.2), let w = Double(m.3), let h = Double(m.4)
	else { return nil }
	return (w / 1000, h / 1000, max(0, (minY + h) / 1000))
}

/// MathJax's error for `tex`, or nil when it typesets.
public func mathParseError(_ tex: String) -> String? {
	switch MathJax.shared.render(tex, display: false) {
	case .success: nil
	case .failure(let e): e.description
	}
}
