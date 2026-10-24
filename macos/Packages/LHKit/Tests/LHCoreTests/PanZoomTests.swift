import Foundation
import Testing
@testable import LHCore

// Port of tests/pan-zoom.test.ts.

@Suite struct FitZoomForTests {
	@Test func bindsOnWidthForAWideBox() {
		#expect(fitZoomFor(BoxSize(w: 800, h: 400), BoxSize(w: 400, h: 300)) == 384.0 / 800)
	}
	@Test func bindsOnHeightForATallBox() {
		#expect(fitZoomFor(BoxSize(w: 400, h: 800), BoxSize(w: 400, h: 300)) == 284.0 / 800)
	}
	@Test func capsTheFitAtFitZoomMax() {
		#expect(fitZoomFor(BoxSize(w: 50, h: 50), BoxSize(w: 1000, h: 1000)) == FIT_ZOOM_MAX)
	}
	@Test func degenerateViewportRendersAt1x() {
		#expect(fitZoomFor(BoxSize(w: 400, h: 300), BoxSize(w: 0, h: 0)) == 1)
	}
}

@Suite struct FitGraphViewTests {
	@Test func centersTheBoxAtTheGivenZoom() {
		#expect(fitGraphView(BoxSize(w: 800, h: 400), BoxSize(w: 400, h: 300), 0.5) == Viewport(zoom: 0.5, x: 0, y: 50))
	}
}

@Suite struct ZoomedGraphViewTests {
	let box = BoxSize(w: 800, h: 400)
	let viewport = BoxSize(w: 400, h: 300)
	var floor: Double { fitZoomFor(box, viewport) }

	@Test func focusStaysVisuallyFixed() {
		let out = zoomedGraphView(Viewport(zoom: 1, x: 0, y: 0), factor: 1.25, floor: floor, focus: (200, 150), box: box, viewport: viewport)
		#expect(out.zoom == 1.25)
		#expect(200 - out.x == 200 * 1.25)
		#expect(150 - out.y == 150 * 1.25)
	}
	@Test func clampsAtTheFloorAndRecenters() {
		let near = Viewport(zoom: floor * 1.1, x: -100, y: 40)
		let out = zoomedGraphView(near, factor: 0.5, floor: floor, focus: (200, 150), box: box, viewport: viewport)
		#expect(out == fitGraphView(box, viewport, floor))
	}
	@Test func clampsAtZoomMax() {
		let atMax = Viewport(zoom: ZOOM_MAX, x: 0, y: 0)
		#expect(zoomedGraphView(atMax, factor: 2, floor: floor, focus: (200, 150), box: box, viewport: viewport) == atMax)
	}
	@Test func noOpsWhenTheFactorLandsOnTheCurrentZoom() {
		let view = Viewport(zoom: 1, x: -37, y: 12)
		#expect(zoomedGraphView(view, factor: 1, floor: floor, focus: (0, 0), box: box, viewport: viewport) == view)
	}
}
