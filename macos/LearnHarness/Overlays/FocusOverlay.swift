import AppKit
import LHCore
import SwiftUI

/// The session-scoped focus overlay (session-overlay.tsx / PlanPopup): it
/// covers the detail column with a dimmed, blurred backdrop; the header
/// names it; the content pans and zooms through the ported pan-zoom math
/// (wheel zooms to the cursor, drag pans only past the fit, −/fit/+ in the
/// corner); Esc closes. The content stays hidden until the first fit.
struct FocusOverlay<Content: View>: View {
	var title: String
	var subtitle: String
	/// The content's natural box (layout units = points at zoom 1).
	var box: CGSize
	var closesOnBackdrop = false
	var onClose: () -> Void
	@ViewBuilder var content: (Viewport) -> Content

	@State private var view = Viewport(zoom: 1, x: 0, y: 0)
	@State private var viewport: CGSize = .zero
	@State private var fitted = false

	private var boxSize: BoxSize { BoxSize(w: box.width, h: box.height) }
	private var portSize: BoxSize { BoxSize(w: viewport.width, h: viewport.height) }
	private var floor: Double { fitZoomFor(boxSize, portSize) }

	var body: some View {
		ZStack {
			Rectangle()
				.fill(.ultraThinMaterial)
				.overlay(Color(nsColor: .windowBackgroundColor).opacity(0.8))
				.onTapGesture { if closesOnBackdrop { onClose() } }
			VStack(spacing: 0) {
				HStack(alignment: .firstTextBaseline, spacing: 12) {
					Text(title).font(.headline)
					Text(subtitle).font(Theme.ui).foregroundStyle(Theme.muted)
					Spacer()
					Button(action: onClose) { Image(systemName: "xmark") }
						.buttonStyle(.borderless)
						.help("Close")
						.keyboardShortcut(.cancelAction)
				}
				.padding(.horizontal, 20)
				.padding(.vertical, 12)
				GeometryReader { geo in
					ZStack {
						content(view)
							.opacity(fitted ? 1 : 0)
						PanZoomSurface(
							onZoom: { factor, point in zoom(factor, at: point, animated: false) },
							onPan: { dx, dy in pan(dx, dy) }
						)
					}
					.onAppear { resize(geo.size) }
					.onChange(of: geo.size) { _, size in resize(size) }
				}
				.clipped()
				.overlay(alignment: .bottomLeading) {
					Text("Drag to pan · scroll to zoom").font(Theme.ui).foregroundStyle(Theme.faint).padding(12)
				}
				.overlay(alignment: .bottomTrailing) {
					HStack(spacing: 4) {
						Button { zoom(1 / 1.25, at: center, animated: true) } label: { Image(systemName: "minus") }.help("Zoom out")
						Button { refit(animated: true) } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.help("Fit")
						Button { zoom(1.25, at: center, animated: true) } label: { Image(systemName: "plus") }.help("Zoom in")
					}
					.buttonStyle(.bordered)
					.controlSize(.small)
					.padding(12)
				}
			}
		}
		.onExitCommand(perform: onClose)
	}

	private var center: CGPoint { CGPoint(x: viewport.width / 2, y: viewport.height / 2) }

	private func resize(_ size: CGSize) {
		guard size.width > 0, size.height > 0 else { return }
		viewport = size
		refit(animated: false)
		fitted = true
	}

	private func refit(animated: Bool) {
		let next = fitGraphView(boxSize, portSize, floor)
		withAnimation(animated ? .easeOut(duration: 0.18) : nil) { view = next }
	}

	private func zoom(_ factor: Double, at point: CGPoint, animated: Bool) {
		let next = zoomedGraphView(view, factor: factor, floor: floor, focus: (point.x, point.y), box: boxSize, viewport: portSize)
		withAnimation(animated ? .easeOut(duration: 0.18) : nil) { view = next }
	}

	/// Panning locks at the floor — fully zoomed out there is nothing to move.
	private func pan(_ dx: Double, _ dy: Double) {
		guard view.zoom > floor + 1e-9 else { return }
		view = Viewport(zoom: view.zoom, x: view.x + dx, y: view.y + dy)
	}
}

/// Scroll-wheel and drag capture for the overlay (SwiftUI has no wheel
/// gesture): wheel → zoom factor `exp(-dy·0.0015)` at the cursor; drag →
/// pan deltas.
struct PanZoomSurface: NSViewRepresentable {
	var onZoom: (Double, CGPoint) -> Void
	var onPan: (Double, Double) -> Void

	func makeNSView(context: Context) -> SurfaceView {
		let v = SurfaceView()
		v.onZoom = onZoom
		v.onPan = onPan
		return v
	}

	func updateNSView(_ v: SurfaceView, context: Context) {
		v.onZoom = onZoom
		v.onPan = onPan
	}

	final class SurfaceView: NSView {
		var onZoom: ((Double, CGPoint) -> Void)?
		var onPan: ((Double, Double) -> Void)?
		private var last: NSPoint?

		override var isFlipped: Bool { true }

		override func scrollWheel(with event: NSEvent) {
			let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
			let p = convert(event.locationInWindow, from: nil)
			onZoom?(exp(Double(dy) * 0.0015), p)
		}

		override func magnify(with event: NSEvent) {
			let p = convert(event.locationInWindow, from: nil)
			onZoom?(1 + Double(event.magnification), p)
		}

		override func mouseDown(with event: NSEvent) {
			last = convert(event.locationInWindow, from: nil)
		}

		override func mouseDragged(with event: NSEvent) {
			let p = convert(event.locationInWindow, from: nil)
			if let last { onPan?(Double(p.x - last.x), Double(p.y - last.y)) }
			last = p
		}

		override func mouseUp(with event: NSEvent) { last = nil }
	}
}
