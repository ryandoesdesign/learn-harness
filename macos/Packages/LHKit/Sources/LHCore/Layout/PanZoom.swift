import Foundation

// Port of components/pan-zoom.ts — the shared "fit floor" viewport math for
// the session overlays (plan popup, diagram focus): fully zoomed out IS the
// fit, panning locks at the floor, the wheel zooms to the cursor.

public let ZOOM_MAX = 4.0
/// Viewport breathing room subtracted by the fit.
public let FIT_PAD = 16.0
/// The fit never zooms IN past this — a tiny diagram must not blow up.
public let FIT_ZOOM_MAX = 1.5

/// A pan/zoom viewport state (translate + scale; origin top-left).
public struct Viewport: Sendable, Hashable {
	public var zoom: Double
	public var x: Double
	public var y: Double
	public init(zoom: Double, x: Double, y: Double) {
		self.zoom = zoom
		self.x = x
		self.y = y
	}
}

public struct BoxSize: Sendable, Hashable {
	public var w: Double
	public var h: Double
	public init(w: Double, h: Double) {
		self.w = w
		self.h = h
	}
}

/// The fit zoom for a box in a viewport, in [0.02, FIT_ZOOM_MAX].
public func fitZoomFor(_ box: BoxSize, _ viewport: BoxSize) -> Double {
	if viewport.w == 0 || viewport.h == 0 || box.w == 0 { return 1 }
	return max(0.02, min((viewport.w - FIT_PAD) / box.w, (viewport.h - FIT_PAD) / box.h, FIT_ZOOM_MAX))
}

/// Centers a box (at the given zoom) in the viewport.
public func fitGraphView(_ box: BoxSize, _ viewport: BoxSize, _ zoom: Double) -> Viewport {
	Viewport(zoom: zoom, x: (viewport.w - box.w * zoom) / 2, y: (viewport.h - box.h * zoom) / 2)
}

/// Zoom by `factor` keeping `focus` (viewport coordinates) fixed, clamped to
/// [floor, ZOOM_MAX]. At the floor the view re-fits and re-centers.
public func zoomedGraphView(_ view: Viewport, factor: Double, floor: Double, focus: (x: Double, y: Double), box: BoxSize, viewport: BoxSize) -> Viewport {
	let zoom = min(max(view.zoom * factor, floor), ZOOM_MAX)
	if zoom == view.zoom { return view }
	if zoom <= floor { return fitGraphView(box, viewport, floor) }
	let k = zoom / view.zoom
	return Viewport(zoom: zoom, x: focus.x - (focus.x - view.x) * k, y: focus.y - (focus.y - view.y) * k)
}
