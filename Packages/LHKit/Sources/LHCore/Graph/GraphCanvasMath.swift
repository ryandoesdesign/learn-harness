import Foundation

// The pure parts of components/graph-canvas.ts, graph-view.tsx and
// cluster-geometry.ts (docs/native-macos-m7.md): zoom and label fades, the
// fit, arrows, picking, label wrapping, the region blur, visibility,
// position seeding, the cost totals and the cluster hue. The renderer in
// the app draws with these.

public struct GraphPoint: Sendable, Hashable {
	public var x: Double
	public var y: Double
	public init(x: Double, y: Double) {
		self.x = x
		self.y = y
	}
}

public struct GraphCamera: Sendable, Hashable, Codable {
	public var k: Double
	public var x: Double
	public var y: Double
	public init(k: Double, x: Double, y: Double) {
		self.k = k
		self.x = x
		self.y = y
	}
	public func toScreen(_ p: GraphPoint) -> GraphPoint { GraphPoint(x: p.x * k + x, y: p.y * k + y) }
	public func toWorld(_ p: GraphPoint) -> GraphPoint { GraphPoint(x: (p.x - x) / k, y: (p.y - y) / k) }
}

public func isImpNodeId(_ id: String) -> Bool { id.hasPrefix("arg_") }

/// The renderer's constants (graph-canvas.ts).
public enum GraphCanvasConstants {
	public static let labelReferenceSize = 12.0
	public static let labelMaxWidth = 170.0
	public static let labelGap = 2.9
	public static let labelLineHeight = 1.3
	public static let labelsFadeRatio = 0.5
	public static let glowScale = 1.7
	public static let glowAlpha = 0.3
	public static let hoverFade = 0.18
	public static let pickingPad = 10.0
	public static let clickSlop = 4.0
	public static let liveAlphaDecay = 0.05
	public static let dragAlphaTarget = 0.3
	public static let simSettleAlpha = 0.005
	public static let commitDebounce = 0.25
	public static let regionEvery = 3
	public static let regionLabelMaxWidth = 220.0
	public static let regionLabelMaxLines = 3
	public static let regionLabelLineHeight = 1.3
	/// d3-zoom scaleExtent.
	public static let minZoom = 0.02
	public static let maxZoom = 40.0
	public static let fitPadding = 40.0
}

/// How far out the camera is relative to the fit (1 = fit; >1 = zoomed out).
public func zoomRatioOf(kFit: Double, k: Double) -> Double { kFit / k }

/// Node labels fade out as the ratio passes `labelZoom` over `span`.
public func labelAlpha(ratio: Double, labelZoom: Double, span: Double? = nil) -> Double {
	min(max(1 - (ratio - labelZoom) / (span ?? labelZoom * GraphCanvasConstants.labelsFadeRatio), 0), 1)
}

public struct GraphBBox: Sendable, Hashable {
	public var minX: Double, maxX: Double, minY: Double, maxY: Double
	public init(minX: Double, maxX: Double, minY: Double, maxY: Double) {
		self.minX = minX
		self.maxX = maxX
		self.minY = minY
		self.maxY = maxY
	}
	public init?(_ points: some Sequence<GraphPoint>) {
		var b = GraphBBox(minX: .infinity, maxX: -.infinity, minY: .infinity, maxY: -.infinity)
		for p in points {
			b.minX = min(b.minX, p.x); b.maxX = max(b.maxX, p.x)
			b.minY = min(b.minY, p.y); b.maxY = max(b.maxY, p.y)
		}
		if !b.minX.isFinite { return nil }
		self = b
	}
}

public func fitTransform(_ bbox: GraphBBox, width w: Double, height h: Double, padding: Double) -> GraphCamera {
	let bw = max(bbox.maxX - bbox.minX, 1e-6), bh = max(bbox.maxY - bbox.minY, 1e-6)
	let k = min((w - 2 * padding) / bw, (h - 2 * padding) / bh)
	let cx = (bbox.minX + bbox.maxX) / 2, cy = (bbox.minY + bbox.maxY) / 2
	return GraphCamera(k: k, x: w / 2 - cx * k, y: h / 2 - cy * k)
}

public struct ArrowGeometry: Sendable, Hashable {
	public var shaftFrom: GraphPoint
	public var shaftTo: GraphPoint
	public var tip: GraphPoint
	public var left: GraphPoint
	public var right: GraphPoint
}

/// An edge from a to b, trimmed by both radii, with a head of `headLength`; nil when coincident.
public func arrowGeometry(_ a: GraphPoint, _ b: GraphPoint, fromRadius: Double, toRadius: Double, headLength: Double) -> ArrowGeometry? {
	let dx = b.x - a.x, dy = b.y - a.y
	let len = (dx * dx + dy * dy).squareRoot()
	if len < 1e-6 { return nil }
	let ux = dx / len, uy = dy / len
	let tip = GraphPoint(x: b.x - ux * toRadius, y: b.y - uy * toRadius)
	let base = GraphPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)
	let halfW = 0.4 * headLength
	return ArrowGeometry(shaftFrom: GraphPoint(x: a.x + ux * fromRadius, y: a.y + uy * fromRadius), shaftTo: base, tip: tip,
		left: GraphPoint(x: base.x - uy * halfW, y: base.y + ux * halfW), right: GraphPoint(x: base.x + uy * halfW, y: base.y - ux * halfW))
}

/// The nearest point within `maxDistance` (strictly), or nil.
public func pickNearest<T>(_ items: [T], at p: GraphPoint, maxDistance: Double, position: (T) -> GraphPoint) -> T? {
	var best: T?
	var bestD = maxDistance * maxDistance
	for item in items {
		let q = position(item)
		let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
		if d < bestD { bestD = d; best = item }
	}
	return best
}

/// graph-canvas.ts wrapLabel: word wrap that never truncates; an overlong
/// word is hard-broken by character.
public func wrapLabel(_ text: String, maxWidth: Double, measure: (String) -> Double) -> [String] {
	var lines: [String] = []
	for word in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
		if let last = lines.last, measure("\(last) \(word)") <= maxWidth {
			lines[lines.count - 1] = "\(last) \(word)"
			continue
		}
		var chunk = ""
		for ch in word {
			if !chunk.isEmpty, measure(chunk + String(ch)) > maxWidth {
				lines.append(chunk)
				chunk = String(ch)
			} else {
				chunk.append(ch)
			}
		}
		if !chunk.isEmpty { lines.append(chunk) }
	}
	return lines
}

/// graph-canvas.ts wrapRegionLabel: at most `maxLines`, the last ellipsized.
public func wrapRegionLabel(_ text: String, maxWidth: Double, maxLines: Int, measure: (String) -> Double) -> [String] {
	if maxLines < 1 || measure(text) <= maxWidth { return [text] }
	var lines: [String] = []
	var pending = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
	while !pending.isEmpty, lines.count < maxLines - 1 {
		var line = ""
		while !pending.isEmpty {
			var word = pending[0]
			let candidate = line.isEmpty ? word : "\(line) \(word)"
			if measure(candidate) <= maxWidth {
				line = candidate
				pending.removeFirst()
				continue
			}
			if line.isEmpty {
				var chunk = ""
				while let first = word.first, measure(chunk + String(first)) <= maxWidth {
					chunk.append(first)
					word.removeFirst()
				}
				if !chunk.isEmpty {
					lines.append(chunk)
					pending[0] = word
				} else {
					lines.append(word)
					pending.removeFirst()
				}
				line = ""
			}
			break
		}
		if !line.isEmpty { lines.append(line) }
		if line.isEmpty, !lines.isEmpty, !pending.isEmpty { continue }
		if line.isEmpty, lines.isEmpty { break }
	}
	let rest = pending.joined(separator: " ")
	if rest.isEmpty { return lines }
	if measure(rest) <= maxWidth { return lines + [rest] }
	var tail = rest
	while tail.count > 1, measure("\(tail)…") > maxWidth { tail.removeLast() }
	return lines + ["\(tail)…"]
}

/// One premultiplied RGBA box-blur round (horizontal then vertical, edge-clamped).
public func boxBlurRound(_ src: [Float], _ tmp: inout [Float], _ dst: inout [Float], width w: Int, height h: Int, radius: Int) {
	if radius <= 0 { dst = src; return }
	let div = Float(radius * 2 + 1)
	for y in 0..<h {
		let row = y * w * 4
		var s = [Float](repeating: 0, count: 4)
		for x in -radius...radius {
			let i = row + min(max(x, 0), w - 1) * 4
			for c in 0..<4 { s[c] += src[i + c] }
		}
		for x in 0..<w {
			let o = row + x * 4
			for c in 0..<4 { tmp[o + c] = s[c] / div }
			let add = row + min(x + radius + 1, w - 1) * 4, sub = row + max(x - radius, 0) * 4
			for c in 0..<4 { s[c] += src[add + c] - src[sub + c] }
		}
	}
	for x in 0..<w {
		let col = x * 4
		var s = [Float](repeating: 0, count: 4)
		for y in -radius...radius {
			let i = col + min(max(y, 0), h - 1) * w * 4
			for c in 0..<4 { s[c] += tmp[i + c] }
		}
		for y in 0..<h {
			let o = col + y * w * 4
			for c in 0..<4 { dst[o + c] = s[c] / div }
			let add = col + min(y + radius + 1, h - 1) * w * 4, sub = col + max(y - radius, 0) * w * 4
			for c in 0..<4 { s[c] += tmp[add + c] - tmp[sub + c] }
		}
	}
}

/// graph-view.tsx isNodeVisible: case-insensitive substring over name or statement.
public func isNodeVisible(name: String, statement: String, query: String) -> Bool {
	let q = query.jsTrimmed.lowercased()
	return q.isEmpty || name.lowercased().contains(q) || statement.lowercased().contains(q)
}

/// Two clusters' circles (centroid, farthest member) intersect — the graph
/// window repairs such a layout on open. Implication nodes and unplaced
/// members are ignored.
public func clustersOverlap(_ clusters: [[String]], positions: [String: Position]) -> Bool {
	let circles: [(x: Double, y: Double, r: Double)] = clusters.compactMap { members in
		let pts = members.filter { !isImpNodeId($0) }.compactMap { positions[$0] }
		guard !pts.isEmpty else { return nil }
		let x = pts.map(\.x).reduce(0, +) / Double(pts.count)
		let y = pts.map(\.y).reduce(0, +) / Double(pts.count)
		return (x, y, pts.map { hypot($0.x - x, $0.y - y) }.max()!)
	}
	for i in circles.indices {
		for j in circles.indices where j > i {
			if hypot(circles[i].x - circles[j].x, circles[i].y - circles[j].y) < circles[i].r + circles[j].r { return true }
		}
	}
	return false
}

/// graph-view.tsx seedMissingNodePositions: missing nodes on a deterministic
/// ring (FNV-1a angle + golden-angle step) around the known bbox.
public func seedMissingNodePositions(_ ids: [String], _ positions: [String: Position]) -> [String: Position] {
	if positions.isEmpty || ids.allSatisfy({ positions[$0] != nil }) { return positions }
	var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
	for p in positions.values {
		minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
	}
	let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
	let radius = max(maxX - minX, maxY - minY, 40) * 0.7 + 20
	var out = positions
	for (i, id) in ids.filter({ positions[$0] == nil }).enumerated() {
		var h: UInt32 = 0x811C9DC5
		for unit in id.utf16 { h = (h ^ UInt32(unit)) &* 0x0100_0193 }
		let angle = (Double(h) / Double(UInt32.max) * 2 * .pi + Double(i) * 2.39996323).truncatingRemainder(dividingBy: 2 * .pi)
		out[id] = Position(x: cx + cos(angle) * radius, y: cy + sin(angle) * radius)
	}
	return out
}

/// graph-view.tsx displayCostTotals: extraction + audit only.
public func displayCostTotals(_ costs: GraphCostSummary) -> (totalDollars: Double, unpricedRuns: Int) {
	(costs.stages.extraction.dollars + costs.stages.audit.dollars, costs.stages.extraction.unpricedRuns + costs.stages.audit.unpricedRuns)
}

/// cluster-geometry.ts clusterHue: a string hash mod 360.
public func clusterHue(_ id: String) -> Double {
	var h = 0
	for scalar in id.unicodeScalars { h = (h * 31 + Int(String(scalar).utf16.first!)) % 360 }
	return Double(h)
}
