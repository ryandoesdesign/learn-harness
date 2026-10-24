import Foundation

// Port of src/core/render-settings.ts (docs/native-macos-m7.md): the graph
// window's display and physics settings, their ladders and log sliders, and
// the lenient sanitizer over the stored JSON (your imported TS file included).

public struct RegionTuning: Sendable, Hashable {
	public var dilation: Double
	public var blur: Double
	public var bitmap: Int
	public var edgeAlpha: Double
	public var enabled: Bool
}

public struct PhysicsTuning: Sendable, Hashable {
	public var chargeStrength: Double
	public var linkStrength: Double
	public var linkDistance: Double
	public var gravity: Double
	public var clusterPull: Double
	public var velocityDecay: Double
	public var depthMode: DepthAnchorMode
	public var depthStrength: Double
	public var depthSpacing: Double
	public var depthBaseRadius: Double
}

public struct GraphRenderSettings: Sendable, Hashable {
	public var nodeSize: Double
	public var edgeWidth: Double
	public var arrowLength: Double
	public var labelZoom: Double
	public var labelSize: Double
	public var clusterLabels: Bool
	public var clusterLabelSize: Double
	public var regions: RegionTuning
	public var physics: PhysicsTuning
}

public let REGION_BITMAP_OPTIONS = [128, 192, 256, 384, 512]
public let DEFAULT_REGION_TUNING = RegionTuning(dilation: 20, blur: 40, bitmap: 256, edgeAlpha: 0.2, enabled: true)
public let DEFAULT_PHYSICS_TUNING = PhysicsTuning(chargeStrength: CHARGE_STRENGTH, linkStrength: 1, linkDistance: LINK_DISTANCE,
	gravity: INCREMENTAL_GRAVITY, clusterPull: CLUSTER_PULL_STRENGTH, velocityDecay: 0.4, depthMode: .off,
	depthStrength: 0.8, depthSpacing: 60, depthBaseRadius: 220)
public let DEFAULT_RENDER_SETTINGS = GraphRenderSettings(nodeSize: 2, edgeWidth: 1, arrowLength: 2, labelZoom: 0.5, labelSize: 3,
	clusterLabels: true, clusterLabelSize: 14, regions: DEFAULT_REGION_TUNING, physics: DEFAULT_PHYSICS_TUNING)

public let NODE_SIZE_LADDER = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12]
public let EDGE_WIDTH_LADDER = [0.1, 0.2, 0.4, 0.6, 0.8, 1, 1.5, 2, 3, 4, 6]
public let ARROW_LENGTH_LADDER = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12]
public let LABEL_SIZE_LADDER = [0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12, 16]
public let CLUSTER_LABEL_SIZE_LADDER: [Double] = [7, 8, 9, 10, 12, 14, 16, 18, 20, 24, 28]
public let LABEL_ZOOM_LADDER = [0.125, 0.175, 0.25, 0.35, 0.45, 0.5, 0.75, 1, 1.5, 2, 3]
public let REGION_DILATION_LADDER = [4, 5, 7.5, 10, 15, 20, 30, 40, 60, 80, 120]
public let REGION_BLUR_LADDER: [Double] = [10, 15, 20, 25, 30, 40, 50, 60, 80, 100, 120]
public let REGION_EDGE_ALPHA_LADDER = [0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.4, 0.6, 0.8, 1]

public struct SliderRange: Sendable, Hashable {
	public var min: Double
	public var max: Double
}
public let CHARGE_RANGE = SliderRange(min: -480, max: -120)
public let LINK_STRENGTH_RANGE = SliderRange(min: 0.25, max: 4)
public let LINK_DISTANCE_RANGE = SliderRange(min: 10, max: 160)
public let GRAVITY_RANGE = SliderRange(min: 0.03, max: 0.48)
public let CLUSTER_PULL_RANGE = SliderRange(min: 0.0225, max: 1)
public let VELOCITY_DECAY_RANGE = SliderRange(min: 0.18, max: 0.9)
public let DEPTH_STRENGTH_RANGE = SliderRange(min: 0.2, max: 3.2)
public let DEPTH_SPACING_RANGE = SliderRange(min: 15, max: 240)
public let DEPTH_BASE_RADIUS_RANGE = SliderRange(min: 55, max: 880)

private func clamp(_ v: Double, _ r: SliderRange) -> Double { min(max(v, r.min), r.max) }
private func num(_ v: JSONValue?) -> Double? { v?.doubleValue.flatMap { $0.isFinite ? $0 : nil } }

/// render-settings.ts sanitizeRenderSettings. A file without
/// `sizeUnits: "world"` (the pre-world-unit format) resets node, arrow and
/// label size and the region dilation.
public func sanitizeRenderSettings(_ raw: JSONValue?) -> GraphRenderSettings {
	let r = raw ?? .null
	let d = DEFAULT_RENDER_SETTINGS
	func ladd(_ key: String, _ ladder: [Double], _ dflt: Double) -> Double { num(r[key]).map { snapToLadder($0, ladder) } ?? dflt }
	let legacy = r["sizeUnits"]?.stringValue != "world"
	var regions = sanitizeRegionTuning(r["regions"])
	if legacy { regions.dilation = DEFAULT_REGION_TUNING.dilation }
	return GraphRenderSettings(
		nodeSize: legacy ? d.nodeSize : ladd("nodeSize", NODE_SIZE_LADDER, d.nodeSize),
		edgeWidth: ladd("edgeWidth", EDGE_WIDTH_LADDER, d.edgeWidth),
		arrowLength: legacy ? d.arrowLength : ladd("arrowLength", ARROW_LENGTH_LADDER, d.arrowLength),
		labelZoom: ladd("labelZoom", LABEL_ZOOM_LADDER, d.labelZoom),
		labelSize: legacy ? d.labelSize : ladd("labelSize", LABEL_SIZE_LADDER, d.labelSize),
		clusterLabels: r["clusterLabels"]?.boolValue ?? d.clusterLabels,
		clusterLabelSize: ladd("clusterLabelSize", CLUSTER_LABEL_SIZE_LADDER, d.clusterLabelSize),
		regions: regions,
		physics: sanitizePhysicsTuning(r["physics"]))
}

public func sanitizeRegionTuning(_ input: JSONValue?) -> RegionTuning {
	let d = DEFAULT_REGION_TUNING
	func ladd(_ key: String, _ ladder: [Double], _ dflt: Double) -> Double { num(input?[key]).map { snapToLadder($0, ladder) } ?? dflt }
	let bitmap = num(input?["bitmap"]) ?? Double(d.bitmap)
	return RegionTuning(
		dilation: ladd("dilation", REGION_DILATION_LADDER, d.dilation),
		blur: ladd("blur", REGION_BLUR_LADDER, d.blur),
		bitmap: Int(snapToLadder(bitmap, REGION_BITMAP_OPTIONS.map(Double.init))),
		edgeAlpha: ladd("edgeAlpha", REGION_EDGE_ALPHA_LADDER, d.edgeAlpha),
		enabled: input?["enabled"]?.boolValue ?? true)
}

public func sanitizePhysicsTuning(_ input: JSONValue?) -> PhysicsTuning {
	let d = DEFAULT_PHYSICS_TUNING
	func v(_ key: String, _ dflt: Double) -> Double { num(input?[key]) ?? dflt }
	let mode = input?["depthMode"]?.stringValue.flatMap(DepthAnchorMode.init(rawValue:)) ?? .off
	return PhysicsTuning(
		chargeStrength: clamp(v("chargeStrength", d.chargeStrength), CHARGE_RANGE),
		linkStrength: clamp(v("linkStrength", d.linkStrength), LINK_STRENGTH_RANGE),
		linkDistance: clamp(v("linkDistance", d.linkDistance), LINK_DISTANCE_RANGE),
		gravity: clamp(v("gravity", d.gravity), GRAVITY_RANGE),
		clusterPull: min(max(v("clusterPull", d.clusterPull), 0), CLUSTER_PULL_RANGE.max),
		velocityDecay: clamp(v("velocityDecay", d.velocityDecay), VELOCITY_DECAY_RANGE),
		depthMode: mode,
		depthStrength: clamp(v("depthStrength", d.depthStrength), DEPTH_STRENGTH_RANGE),
		depthSpacing: clamp(v("depthSpacing", d.depthSpacing), DEPTH_SPACING_RANGE),
		depthBaseRadius: clamp(v("depthBaseRadius", d.depthBaseRadius), DEPTH_BASE_RADIUS_RANGE))
}

extension GraphRenderSettings {
	/// The stored shape (always `sizeUnits: "world"`), round-tripping the sanitizer.
	public var json: JSONValue {
		let rg = regions, p = physics
		return .object(JSONObject(pairs: [
			("sizeUnits", "world"), ("nodeSize", .number(nodeSize)), ("edgeWidth", .number(edgeWidth)), ("arrowLength", .number(arrowLength)),
			("labelZoom", .number(labelZoom)), ("labelSize", .number(labelSize)), ("clusterLabels", .bool(clusterLabels)),
			("clusterLabelSize", .number(clusterLabelSize)),
			("regions", .object(JSONObject(pairs: [("dilation", .number(rg.dilation)), ("blur", .number(rg.blur)), ("bitmap", .number(Double(rg.bitmap))),
				("edgeAlpha", .number(rg.edgeAlpha)), ("enabled", .bool(rg.enabled))]))),
			("physics", .object(JSONObject(pairs: [("chargeStrength", .number(p.chargeStrength)), ("linkStrength", .number(p.linkStrength)),
				("linkDistance", .number(p.linkDistance)), ("gravity", .number(p.gravity)), ("clusterPull", .number(p.clusterPull)),
				("velocityDecay", .number(p.velocityDecay)), ("depthMode", .string(p.depthMode.rawValue)), ("depthStrength", .number(p.depthStrength)),
				("depthSpacing", .number(p.depthSpacing)), ("depthBaseRadius", .number(p.depthBaseRadius))]))),
		]))
	}
}

// MARK: - Ladders and sliders

/// The nearest rung (first wins a tie).
public func snapToLadder(_ value: Double, _ ladder: [Double]) -> Double {
	ladder.reduce(ladder[0]) { abs($1 - value) < abs($0 - value) ? $1 : $0 }
}

public func ladderIndex(_ value: Double, _ ladder: [Double]) -> Int {
	var best = 0
	for i in 1..<ladder.count where abs(ladder[i] - value) < abs(ladder[best] - value) { best = i }
	return best
}

/// A ladder value ↔ a 0…100 slider position in steps of 10.
public func toLadderPosition(_ value: Double, _ ladder: [Double]) -> Double {
	Double(ladderIndex(min(max(value, ladder[0]), ladder[ladder.count - 1]), ladder) * 10)
}

public func fromLadderPosition(_ position: Double, _ ladder: [Double]) -> Double {
	ladder[min(max(Int((position / 10).rounded()), 0), ladder.count - 1)]
}

/// The log slider: 0…100 over [min, max] (both negative for charge).
public func toSliderPosition(_ value: Double, _ r: SliderRange) -> Double {
	100 * log(clamp(value, r) / r.min) / log(r.max / r.min)
}

public func fromSliderPosition(_ position: Double, _ r: SliderRange) -> Double {
	r.min * exp(min(max(position, 0), 100) / 100 * log(r.max / r.min))
}

/// The cluster-pull slider: far left (0) is off.
public func toOffSliderPosition(_ value: Double, _ r: SliderRange) -> Double { value <= 0 ? 0 : toSliderPosition(value, r) }
public func fromOffSliderPosition(_ position: Double, _ r: SliderRange) -> Double { position <= 0 ? 0 : fromSliderPosition(position, r) }

/// "Labels until zoom" shows relative to the default: 0.5 → "1×".
public func labelZoomDisplay(_ labelZoom: Double) -> String {
	let v = (labelZoom / 0.5 * 100).rounded() / 100
	return "\(JSONNumber(v).lexeme)×"
}
