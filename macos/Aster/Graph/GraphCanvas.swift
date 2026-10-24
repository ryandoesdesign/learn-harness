import AppKit
import LHCore
import SwiftUI

/// The graph canvas (graph-canvas.ts, docs/native-macos-m7.md): an AppKit
/// view drawing with Core Graphics, redrawn only on change. Draw order is
/// TS's — regions, edges and arrowheads, node discs, node labels (fading
/// with zoom), the hover halo, cluster labels. Beyond TS: wrapped labels are
/// cached per data change and off-screen nodes and labels are skipped.
/// Mac-native navigation (your answer): two-finger scroll pans, pinch and a
/// mouse wheel zoom at the cursor, dragging empty space pans, dragging a
/// node moves it.
struct GraphCanvas: NSViewRepresentable {
	var model: GraphWindowModel

	func makeNSView(context: Context) -> GraphCanvasView {
		let view = GraphCanvasView(model: model)
		model.redraw = { [weak view] in view?.needsDisplay = true }
		return view
	}

	func updateNSView(_ view: GraphCanvasView, context: Context) { view.needsDisplay = true }
}

final class GraphCanvasView: NSView {
	let model: GraphWindowModel
	private var camera: GraphCamera?
	private var kFit = 1.0
	private var hover: String?
	private var hoverFade = 0.0
	private var hoverTimer: Timer?
	private var press: (id: String?, at: CGPoint, camera: GraphCamera?, dragging: Bool)?
	private var regions = GraphRegions()
	private var regionsVersion = -1
	private var frameCount = 0
	private var labelCache: [String: [String]] = [:]
	private var labelVersion = -1
	private var cameraSave: Timer?
	private static let cameraKey = "aster.graph.camera.v1"

	init(model: GraphWindowModel) {
		self.model = model
		super.init(frame: .zero)
		if let data = UserDefaults.standard.data(forKey: Self.cameraKey), let c = try? JSONDecoder().decode(GraphCamera.self, from: data) { camera = c }
		model.zoomBy = { [weak self] f in self?.zoom(by: f, at: nil) }
		model.fit = { [weak self] in self?.fitToView() }
	}

	required init?(coder: NSCoder) { fatalError() }

	override var isFlipped: Bool { true }
	override var acceptsFirstResponder: Bool { true }

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		trackingAreas.forEach(removeTrackingArea)
		addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
	}

	// MARK: Camera

	private var bbox: GraphBBox? {
		GraphBBox(model.ids.indices.filter { !isImpNodeId(model.ids[$0]) && model.isVisible(model.ids[$0]) }.map { GraphPoint(x: model.positions[$0].x, y: model.positions[$0].y) })
	}

	private func ensureCamera() {
		guard bounds.width > 1, let b = bbox else { return }
		let fit = fitTransform(b, width: bounds.width, height: bounds.height, padding: GraphCanvasConstants.fitPadding)
		kFit = fit.k
		if camera == nil { camera = fit }
	}

	private func fitToView() {
		guard let b = bbox else { return }
		camera = fitTransform(b, width: bounds.width, height: bounds.height, padding: GraphCanvasConstants.fitPadding)
		cameraMoved()
	}

	private func zoom(by factor: Double, at point: CGPoint?) {
		guard var c = camera else { return }
		let p = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
		let k = min(max(c.k * factor, GraphCanvasConstants.minZoom), GraphCanvasConstants.maxZoom)
		let world = c.toWorld(GraphPoint(x: p.x, y: p.y))
		c = GraphCamera(k: k, x: p.x - world.x * k, y: p.y - world.y * k)
		camera = c
		cameraMoved()
	}

	private func pan(_ dx: Double, _ dy: Double) {
		guard var c = camera else { return }
		c.x += dx
		c.y += dy
		camera = c
		cameraMoved()
	}

	/// Any camera move closes the card; the camera persists (debounced).
	private func cameraMoved() {
		model.selected = nil
		needsDisplay = true
		cameraSave?.invalidate()
		cameraSave = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
			MainActor.assumeIsolated {
				if let c = self?.camera, let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: Self.cameraKey) }
			}
		}
	}

	override func setFrameSize(_ newSize: NSSize) {
		// Keep the viewport centre anchored across resizes.
		let old = bounds.size
		super.setFrameSize(newSize)
		if var c = camera, old.width > 1 {
			c.x += (newSize.width - old.width) / 2
			c.y += (newSize.height - old.height) / 2
			camera = c
		}
	}

	// MARK: Input

	private func world(_ p: CGPoint) -> SIMD2<Double> {
		guard let c = camera else { return SIMD2(p.x, p.y) }
		let w = c.toWorld(GraphPoint(x: p.x, y: p.y))
		return SIMD2(w.x, w.y)
	}

	private func pick(_ p: CGPoint) -> String? {
		guard let c = camera else { return nil }
		let w = world(p)
		let candidates = model.ids.indices.filter { !isImpNodeId(model.ids[$0]) && model.isVisible(model.ids[$0]) }
		let maxD = (model.settings.nodeSize * c.k + GraphCanvasConstants.pickingPad) / c.k
		return pickNearest(candidates, at: GraphPoint(x: w.x, y: w.y), maxDistance: maxD) { GraphPoint(x: model.positions[$0].x, y: model.positions[$0].y) }.map { model.ids[$0] }
	}

	private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

	override func mouseDown(with e: NSEvent) {
		window?.makeFirstResponder(self)
		let p = point(e)
		press = (pick(p), p, camera, false)
	}

	override func mouseDragged(with e: NSEvent) {
		guard var pr = press else { return }
		let p = point(e)
		let moved = hypot(p.x - pr.at.x, p.y - pr.at.y)
		if !pr.dragging, moved <= GraphCanvasConstants.clickSlop { return }
		pr.dragging = true
		press = pr
		if let id = pr.id {
			model.selected = nil
			model.drag(id, to: world(p))
		} else if let start = pr.camera {
			camera = GraphCamera(k: start.k, x: start.x + p.x - pr.at.x, y: start.y + p.y - pr.at.y)
			cameraMoved()
		}
	}

	override func mouseUp(with e: NSEvent) {
		guard let pr = press else { return }
		press = nil
		if pr.dragging {
			if let id = pr.id { model.endDrag(id) }
			return
		}
		if let id = pr.id {
			model.selected = (id, pr.at)
		} else {
			model.selected = nil
		}
	}

	override func menu(for event: NSEvent) -> NSMenu? {
		guard let id = pick(point(event)) else { return nil }
		model.selected = nil
		let menu = NSMenu()
		let item = NSMenuItem(title: "Delete", action: #selector(deleteFromMenu(_:)), keyEquivalent: "")
		item.representedObject = id
		item.target = self
		menu.addItem(item)
		return menu
	}

	@objc private func deleteFromMenu(_ item: NSMenuItem) {
		if let id = item.representedObject as? String { model.requestDelete([id]) }
	}

	override func scrollWheel(with e: NSEvent) {
		if e.hasPreciseScrollingDeltas {
			pan(e.scrollingDeltaX, e.scrollingDeltaY)
		} else {
			zoom(by: pow(2, e.scrollingDeltaY * 0.1), at: point(e))
		}
	}

	override func magnify(with e: NSEvent) {
		zoom(by: 1 + e.magnification, at: point(e))
	}

	override func mouseMoved(with e: NSEvent) {
		let id = pick(point(e))
		guard id != hover else { return }
		if id != nil { hover = id }
		animateHover(toward: id == nil ? 0 : 1, clearing: id == nil)
	}

	override func mouseExited(with e: NSEvent) { animateHover(toward: 0, clearing: true) }

	/// The 180 ms halo fade.
	private func animateHover(toward target: Double, clearing: Bool) {
		hoverTimer?.invalidate()
		let step = 1 / (GraphCanvasConstants.hoverFade * 60)
		hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.hoverFade += self.hoverFade < target ? step : -step
				if abs(self.hoverFade - target) <= step {
					self.hoverFade = target
					if clearing { self.hover = nil }
					self.hoverTimer?.invalidate()
				}
				self.needsDisplay = true
			}
		}
	}

	// MARK: Drawing

	private var labelFont: NSFont { NSFont.systemFont(ofSize: model.settings.labelSize, weight: .medium) }

	private func wrappedLabels() -> [String: [String]] {
		if labelVersion == model.dataVersion { return labelCache }
		let font = NSFont.systemFont(ofSize: GraphCanvasConstants.labelReferenceSize, weight: .medium)
		let scale = model.settings.labelSize / GraphCanvasConstants.labelReferenceSize
		let maxW = GraphCanvasConstants.labelMaxWidth * scale
		var out: [String: [String]] = [:]
		for (id, node) in model.nodeById where !isImpNodeId(id) && model.isVisible(id) {
			// Measured at the reference size, scaled to world units.
			out[id] = wrapLabel(node.name, maxWidth: maxW) { ($0 as NSString).size(withAttributes: [.font: font]).width * scale }
		}
		labelCache = out
		labelVersion = model.dataVersion
		return out
	}

	override func draw(_ dirtyRect: NSRect) {
		NSColor.windowBackgroundColor.setFill()
		dirtyRect.fill()
		guard model.snapshot != nil, let cg = NSGraphicsContext.current?.cgContext else { return }
		ensureCamera()
		guard let cam = camera else { return }
		let s = model.settings
		frameCount += 1
		if regionsVersion != model.geometryVersion, !model.simActive || frameCount % GraphCanvasConstants.regionEvery == 0 {
			regions = GraphRegions.build(model, labelFont: NSFont.systemFont(ofSize: s.clusterLabelSize, weight: .medium))
			regionsVersion = model.geometryVersion
		}
		let nodeAlpha = labelAlpha(ratio: zoomRatioOf(kFit: kFit, k: cam.k), labelZoom: s.labelZoom)
		let view = CGRect(origin: CGPoint(x: -cam.x / cam.k, y: -cam.y / cam.k), size: CGSize(width: bounds.width / cam.k, height: bounds.height / cam.k))
		let margin = GraphCanvasConstants.labelMaxWidth * s.labelSize / GraphCanvasConstants.labelReferenceSize
		let cull = view.insetBy(dx: -margin, dy: -margin)

		cg.saveGState()
		cg.translateBy(x: cam.x, y: cam.y)
		cg.scaleBy(x: cam.k, y: cam.k)

		if let image = regions.image {
			cg.interpolationQuality = .medium
			// The bitmap is top-down; the flipped context draws images upside down.
			cg.saveGState()
			cg.translateBy(x: regions.rect.minX, y: regions.rect.maxY)
			cg.scaleBy(x: 1, y: -1)
			cg.draw(image, in: CGRect(origin: .zero, size: regions.rect.size))
			cg.restoreGState()
		}

		let nodeR = s.nodeSize
		let edgeColor = NSColor.secondaryLabelColor.cgColor
		if s.edgeWidth > 0, let snap = model.snapshot {
			let shafts = CGMutablePath(), heads = CGMutablePath()
			for e in snap.edges where model.isVisible(e.from) && model.isVisible(e.to) {
				guard let a = model.position(e.from), let b = model.position(e.to) else { continue }
				if !cull.contains(CGPoint(x: a.x, y: a.y)) && !cull.contains(CGPoint(x: b.x, y: b.y)) && !cull.intersects(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))) { continue }
				let intoImp = isImpNodeId(e.to), outOfImp = isImpNodeId(e.from)
				guard let g = arrowGeometry(GraphPoint(x: a.x, y: a.y), GraphPoint(x: b.x, y: b.y), fromRadius: outOfImp ? 0 : nodeR, toRadius: intoImp ? 0 : nodeR, headLength: s.arrowLength) else { continue }
				shafts.move(to: CGPoint(x: g.shaftFrom.x, y: g.shaftFrom.y))
				if intoImp {
					shafts.addLine(to: CGPoint(x: g.tip.x, y: g.tip.y))
				} else {
					shafts.addLine(to: CGPoint(x: g.shaftTo.x, y: g.shaftTo.y))
					heads.addLines(between: [g.tip, g.left, g.right].map { CGPoint(x: $0.x, y: $0.y) })
					heads.closeSubpath()
				}
			}
			cg.setStrokeColor(edgeColor)
			cg.setFillColor(edgeColor)
			cg.setLineWidth(s.edgeWidth / cam.k)
			cg.setLineCap(.round)
			cg.addPath(shafts)
			cg.strokePath()
			cg.addPath(heads)
			cg.fillPath()
		}

		let discs = CGMutablePath()
		var shown: [(String, SIMD2<Double>)] = []
		for (i, id) in model.ids.enumerated() where !isImpNodeId(id) && model.isVisible(id) {
			let p = model.positions[i]
			guard cull.contains(CGPoint(x: p.x, y: p.y)) else { continue }
			discs.addEllipse(in: CGRect(x: p.x - nodeR, y: p.y - nodeR, width: 2 * nodeR, height: 2 * nodeR))
			shown.append((id, p))
		}
		cg.setFillColor(NSColor.controlAccentColor.cgColor)
		cg.addPath(discs)
		cg.fillPath()

		let labels = wrappedLabels()
		let lineH = s.labelSize * GraphCanvasConstants.labelLineHeight
		func drawLabel(_ lines: [String], at p: SIMD2<Double>, color: NSColor) {
			let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: color]
			for (i, line) in lines.enumerated() {
				let str = line as NSString
				let w = str.size(withAttributes: attrs).width
				str.draw(at: CGPoint(x: p.x - w / 2, y: p.y + nodeR + GraphCanvasConstants.labelGap + Double(i) * lineH), withAttributes: attrs)
			}
		}
		if nodeAlpha > 0.01 {
			let color = NSColor.secondaryLabelColor.withAlphaComponent(nodeAlpha)
			for (id, p) in shown { if let lines = labels[id] { drawLabel(lines, at: p, color: color) } }
		}

		if let h = hover, hoverFade > 0.02, model.isVisible(h), let p = model.position(h) {
			let accent = NSColor.controlAccentColor
			let outer = nodeR * GraphCanvasConstants.glowScale
			let colors = [accent.withAlphaComponent(GraphCanvasConstants.glowAlpha * hoverFade).cgColor, accent.withAlphaComponent(0).cgColor] as CFArray
			if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
				cg.saveGState()
				cg.addEllipse(in: CGRect(x: p.x - outer, y: p.y - outer, width: 2 * outer, height: 2 * outer))
				cg.addEllipse(in: CGRect(x: p.x - nodeR, y: p.y - nodeR, width: 2 * nodeR, height: 2 * nodeR))
				cg.clip(using: .evenOdd)
				cg.drawRadialGradient(grad, startCenter: CGPoint(x: p.x, y: p.y), startRadius: nodeR, endCenter: CGPoint(x: p.x, y: p.y), endRadius: outer, options: [])
				cg.restoreGState()
			}
			drawLabel(labels[h] ?? [], at: p, color: NSColor.labelColor.withAlphaComponent(hoverFade))
		}

		let regionAlpha = 1 - nodeAlpha
		if s.clusterLabels, regionAlpha > 0.01 {
			let font = NSFont.systemFont(ofSize: s.clusterLabelSize / cam.k, weight: .medium)
			let lh = s.clusterLabelSize * GraphCanvasConstants.regionLabelLineHeight / cam.k
			for m in regions.meta {
				guard let lines = m.lines, cull.contains(m.center) else { continue }
				let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: hsl(m.hue, 0.55, 0.78, 0.85 * regionAlpha)) ?? .labelColor]
				let first = -Double(lines.count - 1) / 2 * lh
				for (i, line) in lines.enumerated() {
					let str = line as NSString
					let size = str.size(withAttributes: attrs)
					str.draw(at: CGPoint(x: m.center.x - size.width / 2, y: m.center.y + first + Double(i) * lh - size.height / 2), withAttributes: attrs)
				}
			}
		}
		cg.restoreGState()
	}

	/// View coordinates of a node (the detail card's anchor).
	func viewPoint(_ id: String) -> CGPoint? {
		guard let c = camera, let p = model.position(id) else { return nil }
		let s = c.toScreen(GraphPoint(x: p.x, y: p.y))
		return CGPoint(x: s.x, y: s.y)
	}
}
