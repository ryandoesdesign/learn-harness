import AppKit
import LHMarkdown

/// MathJax SVG → template images (math takes the surrounding text color),
/// sized like KaTeX (1.21em of the surrounding text, as in the TS app) and
/// vector-sharp at any scale. Cached by (TeX, size, mode).
@MainActor
enum MathImage {
	struct Rendered {
		var image: NSImage
		/// Distance below the baseline (inline math sits on it).
		var descent: CGFloat
	}

	/// KaTeX's `.katex { font-size: 1.21em }`.
	static let scale: CGFloat = 1.21

	private struct Key: Hashable {
		var tex: String
		var size: CGFloat
		var display: Bool
	}

	private static var cache: [Key: Rendered?] = [:]

	/// nil when MathJax can't typeset the TeX (the caller shows the raw TeX
	/// in red — KaTeX's throwOnError:false fallback).
	static func render(_ tex: String, size: CGFloat, display: Bool) -> Rendered? {
		let key = Key(tex: tex, size: size, display: display)
		if let hit = cache[key] { return hit }
		var rendered: Rendered?
		if case .success(let math) = MathJax.shared.render(tex, display: display), let image = NSImage(data: Data(math.svg.utf8)) {
			let em = size * scale
			image.size = NSSize(width: ceil(math.widthEm * em), height: ceil(math.heightEm * em))
			image.isTemplate = true
			rendered = Rendered(image: image, descent: math.depthEm * em)
		}
		cache[key] = rendered
		return rendered
	}
}
