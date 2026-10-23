import Foundation

// Port of src/core/clusters.ts — the one cluster presentation rule the
// snapshot and the renderer share (detection is birth-session clustering,
// SessionClusters.swift).

/// Communities below this size are not rendered, not named: a region of the
/// world model needs at least three propositions to earn a hull and a label.
public let MIN_CLUSTER_SIZE = 3
