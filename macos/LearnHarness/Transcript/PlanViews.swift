import LHCore
import SwiftUI

/// The plan DAG drawn natively (plan-block.tsx PlanDiagram's skin over the
/// native layered layout): rectangular boxes hugging their wrapped titles,
/// arrows docked off the target face. Monochrome in the transcript; the
/// popup shows status: visited/current full ink, upcoming grey, the current
/// node with a blurred yellow glow; an arrow is dimmed when either end is
/// upcoming.
struct PlanCanvas: View {
	var layout: PlanLayoutResult
	var status: ((String) -> PlanNodeStatus)?
	var current: String?
	/// Layout units → points, and the origin offset (pan/zoom).
	var zoom: Double = 1
	var offset: CGPoint = .zero
	var pad: Double = PLAN_GRAPH_PAD

	var body: some View {
		Canvas { ctx, _ in
			ctx.translateBy(x: offset.x, y: offset.y)
			ctx.scaleBy(x: zoom, y: zoom)
			ctx.translateBy(x: pad, y: pad)
			for e in layout.edges { drawEdge(e, in: &ctx) }
			for n in layout.nodes { drawNode(n, in: &ctx) }
		}
	}

	private func isUpcoming(_ id: String) -> Bool { status?(id) == .upcoming }

	private func drawEdge(_ e: PlacedPlanEdge, in ctx: inout GraphicsContext) {
		guard e.points.count >= 2 else { return }
		let dim = status != nil && (isUpcoming(e.from) || isUpcoming(e.to))
		let ink: Color = dim ? Theme.border : .primary
		var pts = e.points.map { CGPoint(x: $0.x, y: $0.y) }
		// Dock the head off the target's top face; the shaft ends at the head.
		let headH = 16.0 / 1.5
		let dockGap = 4.0 / 1.5
		let tip = CGPoint(x: pts[pts.count - 1].x, y: pts[pts.count - 1].y - dockGap)
		let prev = pts[pts.count - 2]
		let len = max(hypot(tip.x - prev.x, tip.y - prev.y), 1)
		let ux = (tip.x - prev.x) / len
		let uy = (tip.y - prev.y) / len
		let mouth = CGPoint(x: tip.x - ux * headH * 0.46, y: tip.y - uy * headH * 0.46)
		pts[pts.count - 1] = mouth
		var path = Path()
		path.move(to: pts[0])
		if pts.count == 2 {
			path.addLine(to: pts[1])
		} else {
			// A basis-like curve through the waypoints (midpoint quads).
			for i in 1..<(pts.count - 1) {
				let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
				path.addQuadCurve(to: i == pts.count - 2 ? pts[i + 1] : mid, control: pts[i])
			}
		}
		ctx.stroke(path, with: .color(ink), lineWidth: 1)
		// The head: a narrow barbed arrow (the CM long-arrow silhouette, simplified).
		let nx = -uy
		let ny = ux
		let back = CGPoint(x: tip.x - ux * headH * 0.75, y: tip.y - uy * headH * 0.75)
		var head = Path()
		head.move(to: tip)
		head.addQuadCurve(to: CGPoint(x: back.x + nx * headH * 0.45, y: back.y + ny * headH * 0.45), control: CGPoint(x: tip.x - ux * headH * 0.3 + nx * headH * 0.1, y: tip.y - uy * headH * 0.3 + ny * headH * 0.1))
		head.addLine(to: mouth)
		head.addLine(to: CGPoint(x: back.x - nx * headH * 0.45, y: back.y - ny * headH * 0.45))
		head.addQuadCurve(to: tip, control: CGPoint(x: tip.x - ux * headH * 0.3 - nx * headH * 0.1, y: tip.y - uy * headH * 0.3 - ny * headH * 0.1))
		ctx.fill(head, with: .color(ink))
	}

	private func drawNode(_ n: PlacedPlanNode, in ctx: inout GraphicsContext) {
		let rect = CGRect(x: n.x, y: n.y, width: n.w, height: n.h)
		let s = status?(n.id)
		if status != nil, n.id == current {
			var glow = ctx
			glow.addFilter(.blur(radius: PLAN_GLOW_BLUR))
			glow.fill(Path(rect.insetBy(dx: -PLAN_GLOW_MARGIN, dy: -PLAN_GLOW_MARGIN)), with: .color(.yellow.opacity(0.25)))
		}
		let upcoming = s == .upcoming
		ctx.fill(Path(rect), with: .color(upcoming || status == nil ? Theme.card : Color(nsColor: .windowBackgroundColor).opacity(0.5)))
		ctx.stroke(Path(rect), with: .color(upcoming ? Theme.border : .primary), lineWidth: 1)
		let lineH = PLAN_LINE_H
		let y0 = (n.h - Double(n.lines.count) * lineH) / 2 + 10
		for (i, line) in n.lines.enumerated() {
			let text = Text(line)
				.font(.system(size: 12.5, weight: s == .current ? .medium : .regular, design: .serif))
				.foregroundStyle(upcoming ? Theme.muted.opacity(0.8) : Color.primary)
			ctx.draw(text, at: CGPoint(x: n.x + n.w / 2, y: n.y + y0 + Double(i) * lineH), anchor: .bottom)
		}
	}
}

/// The in-chat plan block (PlanBlock): the frozen snapshot, monochrome,
/// column-filling but never past the prose size; click opens the live plan.
struct PlanBlockView: View {
	var data: PlanBlockData
	@Environment(SessionOverlays.self) private var overlays: SessionOverlays?

	var body: some View {
		let layout = planLayout(data.nodes.map { PlanLayoutNode(id: $0.id, title: $0.title) }, data.edges)
		let w = layout.width + 2 * PLAN_GRAPH_PAD
		let h = layout.height + 2 * PLAN_GRAPH_PAD
		Button {
			overlays?.openPlan()
		} label: {
			GeometryReader { geo in
				let scale = min(geo.size.width / w, PLAN_TEXT_CAP_SCALE)
				PlanCanvas(layout: layout, zoom: scale, offset: CGPoint(x: (geo.size.width - w * scale) / 2, y: 0))
			}
			.aspectRatio(w / h, contentMode: .fit)
			.frame(maxWidth: w * PLAN_TEXT_CAP_SCALE)
			.frame(maxWidth: .infinity)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help("Open the full plan")
		.accessibilityLabel("Open the full plan")
		.padding(.vertical, 8)
	}
}

/// The live plan popup: the latest tree, statuses derived now.
struct PlanPopup: View {
	var tree: PlanTree?
	var messages: [Message]
	var onClose: () -> Void

	var body: some View {
		if let tree, !tree.nodes.isEmpty {
			let layout = planLayout(tree.nodes.map { PlanLayoutNode(id: $0.id, title: $0.title) }, tree.edges)
			let statuses = derivePlanStatuses(tree, messages)
			let pad = PLAN_GLOW_REACH
			FocusOverlay(
				title: "The plan",
				subtitle: "live — statuses derive from your check outcomes",
				box: CGSize(width: layout.width + 2 * pad, height: layout.height + 2 * pad),
				closesOnBackdrop: true,
				onClose: onClose
			) { v in
				PlanCanvas(layout: layout, status: { derivedNodeStatus(statuses, $0) }, current: statuses.current,
					zoom: v.zoom, offset: CGPoint(x: v.x, y: v.y), pad: pad)
			}
		} else {
			FocusOverlay(title: "The plan", subtitle: "", box: CGSize(width: 1, height: 1), closesOnBackdrop: true, onClose: onClose) { _ in
				Text("No plan in this session yet.").font(Theme.small).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
	}
}
