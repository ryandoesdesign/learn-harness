import LHCore
import SwiftUI

/// The gear popover (graph-view.tsx GraphSettingsControl): every TS control
/// with its ladders, ranges and displays (your answer: all of it).
struct GraphSettingsPanel: View {
	@Bindable var model: GraphWindowModel

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 10) {
				section("Display")
				ladder("Node size", \.nodeSize, NODE_SIZE_LADDER)
				ladder("Edge width", \.edgeWidth, EDGE_WIDTH_LADDER)
				ladder("Arrowhead size", \.arrowLength, ARROW_LENGTH_LADDER)
				ladder("Label size", \.labelSize, LABEL_SIZE_LADDER)
				ladder("Labels until zoom", \.labelZoom, LABEL_ZOOM_LADDER, display: labelZoomDisplay)

				Divider()
				section("Regions")
				Toggle("Background colors", isOn: $model.settings.regions.enabled)
				Group {
					ladder("Dilation", \.regions.dilation, REGION_DILATION_LADDER)
					ladder("Blur", \.regions.blur, REGION_BLUR_LADDER)
					ladder("Edge alpha", \.regions.edgeAlpha, REGION_EDGE_ALPHA_LADDER)
					HStack {
						Text("Bitmap resolution")
						Spacer()
						Picker("Bitmap resolution", selection: $model.settings.regions.bitmap) {
							ForEach(REGION_BITMAP_OPTIONS, id: \.self) { Text("\($0)").tag($0) }
						}
						.labelsHidden()
						.fixedSize()
					}
				}
				.disabled(!model.settings.regions.enabled)
				Toggle("Cluster labels", isOn: $model.settings.clusterLabels)
				ladder("Cluster label size", \.clusterLabelSize, CLUSTER_LABEL_SIZE_LADDER).disabled(!model.settings.clusterLabels)

				Divider()
				section("Physics")
				log("Node repulsion", \.physics.chargeStrength, CHARGE_RANGE, display: { "-\(Int((-$0).rounded()))" })
				log("Edge attraction", \.physics.linkStrength, LINK_STRENGTH_RANGE)
				log("Edge length", \.physics.linkDistance, LINK_DISTANCE_RANGE)
				log("Central pull", \.physics.gravity, GRAVITY_RANGE)
				slider("Cluster pull", \.physics.clusterPull, to: { toOffSliderPosition($0, CLUSTER_PULL_RANGE) }, from: { fromOffSliderPosition($0, CLUSTER_PULL_RANGE) },
					display: { $0 <= 0 ? "off" : sizeDisplay($0) })
				log("Friction", \.physics.velocityDecay, VELOCITY_DECAY_RANGE)

				Divider()
				HStack {
					section("Depth anchor")
					Spacer()
					Picker("Depth anchor", selection: $model.settings.physics.depthMode) {
						Text("Off").tag(DepthAnchorMode.off)
						Text("Vertical (up)").tag(DepthAnchorMode.vertical)
						Text("Radial (outward)").tag(DepthAnchorMode.radial)
					}
					.labelsHidden()
					.fixedSize()
				}
				Group {
					log("Depth strength", \.physics.depthStrength, DEPTH_STRENGTH_RANGE)
					log("Depth spacing", \.physics.depthSpacing, DEPTH_SPACING_RANGE)
					log("Base ring radius", \.physics.depthBaseRadius, DEPTH_BASE_RADIUS_RANGE).disabled(model.settings.physics.depthMode != .radial)
				}
				.disabled(model.settings.physics.depthMode == .off)
			}
			.font(.system(size: 11))
			.padding(12)
		}
		.frame(width: 300, height: 520)
	}

	private func section(_ title: String) -> some View {
		Text(title.uppercased()).font(.system(size: 10, weight: .medium)).tracking(0.6).foregroundStyle(.secondary)
	}

	private func ladder(_ label: String, _ key: WritableKeyPath<GraphRenderSettings, Double>, _ rungs: [Double], display: @escaping (Double) -> String = sizeDisplay) -> some View {
		slider(label, key, to: { toLadderPosition($0, rungs) }, from: { fromLadderPosition($0, rungs) }, display: display, step: 10)
	}

	private func log(_ label: String, _ key: WritableKeyPath<GraphRenderSettings, Double>, _ range: SliderRange, display: @escaping (Double) -> String = sizeDisplay) -> some View {
		slider(label, key, to: { toSliderPosition($0, range) }, from: { fromSliderPosition($0, range) }, display: display)
	}

	private func slider(_ label: String, _ key: WritableKeyPath<GraphRenderSettings, Double>, to: @escaping (Double) -> Double, from: @escaping (Double) -> Double,
		display: @escaping (Double) -> String, step: Double? = nil) -> some View
	{
		let value = model.settings[keyPath: key]
		let binding = Binding<Double>(get: { to(model.settings[keyPath: key]) }, set: { model.settings[keyPath: key] = from($0) })
		return VStack(alignment: .leading, spacing: 2) {
			HStack {
				Text(label)
				Spacer()
				Text(display(value)).monospacedDigit().foregroundStyle(.secondary)
			}
			if let step { Slider(value: binding, in: 0...100, step: step).controlSize(.small) } else { Slider(value: binding, in: 0...100).controlSize(.small) }
		}
	}
}

/// graph-view.tsx sizeDisplay: "2", "1.6", "0.75".
nonisolated func sizeDisplay(_ v: Double) -> String {
	let r = v >= 1 ? (v * 10).rounded() / 10 : (v * 100).rounded() / 100
	return r == r.rounded() ? "\(Int(r))" : "\(r)"
}

/// The cost pill's panel (graph-view.tsx GraphCostPanel): extraction + audit only.
struct GraphCostPanel: View {
	var costs: GraphCostSummary

	var body: some View {
		let totals = displayCostTotals(costs)
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Text("GRAPH PIPELINE COSTS").font(.system(size: 10, weight: .medium)).tracking(0.6).foregroundStyle(.secondary)
				Spacer()
				Text("$\(String(format: "%.2f", totals.totalDollars))") + Text(totals.unpricedRuns > 0 ? " · \(totals.unpricedRuns) unpriced" : "").foregroundStyle(.secondary)
			}
			ForEach([("Extraction", costs.stages.extraction), ("Audit", costs.stages.audit)], id: \.0) { label, stage in
				HStack {
					Text(label)
					Spacer()
					Text(runCost(stage.runs == 0 || (stage.unpricedRuns > 0 && stage.dollars == 0) ? nil : stage.dollars))
						+ Text(stage.unpricedRuns > 0 && stage.dollars > 0 ? " +\(stage.unpricedRuns) unpriced" : "").foregroundStyle(.secondary)
						+ Text(" · \(fmtTokens(stage.tokens.inputTokens)) in / \(fmtTokens(stage.tokens.outputTokens)) out").foregroundStyle(.secondary)
				}
			}
			if !costs.runs.isEmpty {
				Divider()
				ForEach(Array(costs.runs.enumerated()), id: \.offset) { _, run in
					HStack {
						Text(timeAgo(run.startedAt)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
						Text(run.title).lineLimit(1).truncationMode(.tail)
						if let merged = run.merged { Text("+\(merged.nodes)n").foregroundStyle(.secondary) }
						Spacer()
						Text(runCost(run.dollars))
					}
				}
			}
		}
		.font(.system(size: 11))
		.monospacedDigit()
		.padding(12)
		.frame(width: 300)
	}

	private func runCost(_ d: Double?) -> String { d.map { "$\(String(format: "%.3f", $0))" } ?? "—" }
	private func fmtTokens(_ n: Int?) -> String {
		guard let n else { return "—" }
		if n < 1000 { return "\(n)" }
		if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1000) }
		return String(format: "%.2fM", Double(n) / 1_000_000)
	}
	private func timeAgo(_ ms: Int) -> String {
		let mins = Int((Date().timeIntervalSince1970 * 1000 - Double(ms)) / 60_000)
		if mins < 1 { return "now" }
		if mins < 60 { return "\(mins)m" }
		let hours = Int((Double(mins) / 60).rounded())
		return hours < 24 ? "\(hours)h" : "\(Int((Double(hours) / 24).rounded()))d"
	}
}
