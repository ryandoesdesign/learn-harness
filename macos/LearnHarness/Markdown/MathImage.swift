import AppKit
import LHMarkdown
import SwiftMath

/// SwiftMath → template images (so math takes the surrounding text color),
/// with the baseline offset inline math needs. Cached by (TeX, size, mode).
@MainActor
enum MathImage {
	struct Rendered {
		var image: NSImage
		/// Distance below the baseline (inline math sits on it).
		var descent: CGFloat
	}

	private struct Key: Hashable {
		var tex: String
		var size: CGFloat
		var display: Bool
	}

	private static var cache: [Key: Rendered?] = [:]
	private static let label = MTMathUILabel(frame: .zero)

	/// nil when SwiftMath can't typeset the TeX (the caller shows the raw
	/// TeX in red — KaTeX's throwOnError:false fallback).
	static func render(_ tex: String, size: CGFloat, display: Bool) -> Rendered? {
		let key = Key(tex: tex, size: size, display: display)
		if let hit = cache[key] { return hit }
		let rendered = draw(normalizedTeX(tex), size: size, display: display)
		cache[key] = rendered
		return rendered
	}

	private static func draw(_ tex: String, size: CGFloat, display: Bool) -> Rendered? {
		label.labelMode = display ? .display : .text
		label.fontSize = size
		label.textColor = .black
		label.textAlignment = .left
		label.latex = tex
		guard label.error == nil else { return nil }
		label.frame = NSRect(origin: .zero, size: label.intrinsicContentSize)
		label.layout()
		guard let list = label.displayList else { return nil }
		let width = ceil(list.width)
		let ascent = ceil(list.ascent)
		let descent = ceil(list.descent)
		guard width > 0, ascent + descent > 0 else { return nil }
		// layout() placed the list at (0, descent) inside its intrinsic frame.
		let image = NSImage(size: NSSize(width: width, height: ascent + descent), flipped: false) { _ in
			guard let context = NSGraphicsContext.current?.cgContext else { return false }
			context.saveGState()
			list.draw(context)
			context.restoreGState()
			return true
		}
		image.isTemplate = true
		return Rendered(image: image, descent: descent)
	}
}
