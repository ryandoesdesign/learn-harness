import AppKit
import CoreGraphics
import LHCore

/// The cluster regions (graph-canvas.ts buildRegions): each cluster's
/// intra-cluster edges as round-cap strokes of width 2×dilation, discs for
/// members no edge touches, all into one low-res world-space bitmap; three
/// premultiplied box-blur rounds (the ported boxBlurRound); alpha scaled by
/// edgeAlpha once.
struct GraphRegions {
	struct Meta {
		var id: String
		var label: String?
		var center: CGPoint
		var hue: Double
		var lines: [String]?
	}

	var image: CGImage?
	/// The bitmap's world rect.
	var rect: CGRect = .zero
	var meta: [Meta] = []

	@MainActor
	static func build(_ model: GraphWindowModel, labelFont: NSFont) -> GraphRegions {
		guard let snap = model.snapshot, !snap.clusters.isEmpty else { return GraphRegions() }
		let tuning = model.settings.regions
		var out = GraphRegions()
		var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
		var clusterOf: [String: Int] = [:]
		for (ci, c) in snap.clusters.enumerated() {
			var n = 0, sx = 0.0, sy = 0.0
			for id in c.members {
				clusterOf[id] = ci
				guard model.isVisible(id), let p = model.position(id) else { continue }
				minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
				n += 1; sx += p.x; sy += p.y
			}
			if n > 0 {
				let label = (c.label?.isEmpty ?? true) ? nil : c.label
				let measure: (String) -> Double = { ($0 as NSString).size(withAttributes: [.font: labelFont]).width }
				out.meta.append(Meta(id: c.id, label: label, center: CGPoint(x: sx / Double(n), y: sy / Double(n)), hue: clusterHue(c.id),
					lines: label.map { wrapRegionLabel($0, maxWidth: GraphCanvasConstants.regionLabelMaxWidth, maxLines: GraphCanvasConstants.regionLabelMaxLines, measure: measure) }))
			}
		}
		guard minX <= maxX, tuning.enabled else { return out }

		let pad = tuning.dilation + tuning.blur * 2
		let cell = max(max(maxX - minX, maxY - minY), pad * 2) / Double(tuning.bitmap)
		minX -= pad; minY -= pad; maxX += pad; maxY += pad
		let bw = max(1, Int(((maxX - minX) / cell).rounded(.up))), bh = max(1, Int(((maxY - minY) / cell).rounded(.up)))
		guard let ctx = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: bw * 4,
			space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return out }
		// Top-down rows, like the canvas.
		ctx.translateBy(x: 0, y: Double(bh))
		ctx.scaleBy(x: 1, y: -1)
		ctx.setLineCap(.round)
		ctx.setLineWidth(tuning.dilation * 2 / cell)
		func pt(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: (p.x - minX) / cell, y: (p.y - minY) / cell) }
		for (ci, c) in snap.clusters.enumerated() {
			let color = hsl(clusterHue(c.id), 0.65, 0.6)
			ctx.setStrokeColor(color)
			ctx.setFillColor(color)
			var touched = Set<String>()
			for e in snap.edges where clusterOf[e.from] == ci && clusterOf[e.to] == ci && model.isVisible(e.from) && model.isVisible(e.to) {
				guard let a = model.position(e.from), let b = model.position(e.to) else { continue }
				ctx.move(to: pt(a))
				ctx.addLine(to: pt(b))
				touched.insert(e.from)
				touched.insert(e.to)
			}
			ctx.strokePath()
			let r = tuning.dilation / cell
			for id in c.members where !touched.contains(id) && model.isVisible(id) {
				guard let p = model.position(id) else { continue }
				let c = pt(p)
				ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
			}
		}
		guard let data = ctx.data else { return out }
		let n = bw * bh * 4
		let bytes = data.bindMemory(to: UInt8.self, capacity: n)
		// CGContext stores premultiplied bytes; the TS premultiplies the
		// straight canvas bytes the same way, so blur these directly.
		var a = [Float](repeating: 0, count: n), b = a, tmp = a
		for i in 0..<n { a[i] = Float(bytes[i]) }
		let radius = tuning.blur > 0 ? max(1, Int((tuning.blur / cell).rounded())) : 0
		boxBlurRound(a, &tmp, &b, width: bw, height: bh, radius: radius)
		boxBlurRound(b, &tmp, &a, width: bw, height: bh, radius: radius)
		boxBlurRound(a, &tmp, &b, width: bw, height: bh, radius: radius)
		// Scale the (premultiplied) result by edgeAlpha: colour and alpha together.
		let k = Float(tuning.edgeAlpha)
		for i in 0..<n { bytes[i] = UInt8(min(255, max(0, (b[i] * k).rounded()))) }
		out.image = ctx.makeImage()
		out.rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
		return out
	}
}

/// CSS `hsla(h, s, l, a)` (h in degrees) as a CGColor.
func hsl(_ h: Double, _ s: Double, _ l: Double, _ a: Double = 1) -> CGColor {
	let v = l + s * min(l, 1 - l)
	let sv = v == 0 ? 0 : 2 * (1 - l / v)
	return NSColor(hue: h / 360, saturation: sv, brightness: v, alpha: a).cgColor
}
