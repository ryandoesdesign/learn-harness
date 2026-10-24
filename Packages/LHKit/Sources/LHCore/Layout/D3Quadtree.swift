import Foundation

// Port of the d3-quadtree 3.0.1 subset that forceManyBody uses: addAll (with
// cover), visit and visitAfter. Quads live in a flat array. An internal quad
// has four optional children; a leaf holds one point index plus a `next`
// chain of coincident points (d3 puts the newest at the head).

struct D3Quadtree {
	struct Quad {
		/// Child quad indices (-1 = empty); only meaningful when `isInternal`.
		var children: (Int, Int, Int, Int) = (-1, -1, -1, -1)
		var isInternal: Bool
		/// Leaf: the point's index into the caller's arrays.
		var data: Int = -1
		/// Leaf: the next coincident leaf (-1 = end of chain).
		var next: Int = -1
		/// forceManyBody's accumulated charge and centre of charge.
		var value: Double = 0
		var x: Double = 0
		var y: Double = 0

		subscript(i: Int) -> Int {
			get {
				switch i {
				case 0: children.0
				case 1: children.1
				case 2: children.2
				default: children.3
				}
			}
			set {
				switch i {
				case 0: children.0 = newValue
				case 1: children.1 = newValue
				case 2: children.2 = newValue
				default: children.3 = newValue
				}
			}
		}
	}

	private(set) var quads: [Quad] = []
	private(set) var root = -1
	private(set) var x0 = Double.nan
	private(set) var y0 = Double.nan
	private(set) var x1 = Double.nan
	private(set) var y1 = Double.nan
	/// The points' coordinates, by data index.
	private let px: [Double]
	private let py: [Double]

	/// `quadtree(nodes, x, y)` = an empty tree + `addAll`.
	init(xs: [Double], ys: [Double]) {
		px = xs
		py = ys
		quads.reserveCapacity(xs.count * 2)
		addAll()
	}

	private mutating func newInternal() -> Int {
		quads.append(Quad(isInternal: true))
		return quads.count - 1
	}

	private mutating func newLeaf(_ d: Int) -> Int {
		quads.append(Quad(isInternal: false, data: d))
		return quads.count - 1
	}

	private mutating func addAll() {
		let n = px.count
		var valid = [Bool](repeating: false, count: n)
		var ex0 = Double.infinity
		var ey0 = Double.infinity
		var ex1 = -Double.infinity
		var ey1 = -Double.infinity
		for i in 0..<n {
			let x = px[i]
			let y = py[i]
			if x.isNaN || y.isNaN { continue }
			valid[i] = true
			if x < ex0 { ex0 = x }
			if x > ex1 { ex1 = x }
			if y < ey0 { ey0 = y }
			if y > ey1 { ey1 = y }
		}
		if ex0 > ex1 || ey0 > ey1 { return }
		cover(ex0, ey0)
		cover(ex1, ey1)
		for i in 0..<n where valid[i] {
			add(px[i], py[i], i)
		}
	}

	private mutating func cover(_ x: Double, _ y: Double) {
		if x.isNaN || y.isNaN { return }
		var x0 = self.x0
		var y0 = self.y0
		var x1 = self.x1
		var y1 = self.y1
		if x0.isNaN {
			x0 = x.rounded(.down)
			x1 = x0 + 1
			y0 = y.rounded(.down)
			y1 = y0 + 1
		} else {
			var z = x1 - x0
			if z == 0 || z.isNaN { z = 1 }
			// d3 wraps the root in fresh parents while doubling, but keeps
			// them only when the root is internal (a leaf or empty root
			// stays as is).
			let keep = root >= 0 && quads[root].isInternal
			var node = root
			while x0 > x || x >= x1 || y0 > y || y >= y1 {
				let i = (y < y0 ? 2 : 0) | (x < x0 ? 1 : 0)
				if keep {
					let parent = newInternal()
					quads[parent][i] = node
					node = parent
				}
				z *= 2
				switch i {
				case 0: x1 = x0 + z; y1 = y0 + z
				case 1: x0 = x1 - z; y1 = y0 + z
				case 2: x1 = x0 + z; y0 = y1 - z
				default: x0 = x1 - z; y0 = y1 - z
				}
			}
			if keep { root = node }
		}
		self.x0 = x0
		self.y0 = y0
		self.x1 = x1
		self.y1 = y1
	}

	private mutating func add(_ x: Double, _ y: Double, _ d: Int) {
		if x.isNaN || y.isNaN { return }
		let leaf = newLeaf(d)
		if root < 0 {
			root = leaf
			return
		}
		var x0 = self.x0
		var y0 = self.y0
		var x1 = self.x1
		var y1 = self.y1
		var parent = -1
		var node = root
		var i = 0
		var xm = 0.0
		var ym = 0.0
		while quads[node].isInternal {
			xm = (x0 + x1) / 2
			let right = x >= xm
			if right { x0 = xm } else { x1 = xm }
			ym = (y0 + y1) / 2
			let bottom = y >= ym
			if bottom { y0 = ym } else { y1 = ym }
			i = (bottom ? 2 : 0) | (right ? 1 : 0)
			parent = node
			node = quads[node][i]
			if node < 0 {
				quads[parent][i] = leaf
				return
			}
		}
		let xp = px[quads[node].data]
		let yp = py[quads[node].data]
		if x == xp && y == yp {
			quads[leaf].next = node
			if parent >= 0 { quads[parent][i] = leaf } else { root = leaf }
			return
		}
		var j = 0
		repeat {
			let fresh = newInternal()
			if parent >= 0 { quads[parent][i] = fresh } else { root = fresh }
			parent = fresh
			xm = (x0 + x1) / 2
			let right = x >= xm
			if right { x0 = xm } else { x1 = xm }
			ym = (y0 + y1) / 2
			let bottom = y >= ym
			if bottom { y0 = ym } else { y1 = ym }
			i = (bottom ? 2 : 0) | (right ? 1 : 0)
			j = (yp >= ym ? 2 : 0) | (xp >= xm ? 1 : 0)
		} while i == j
		quads[parent][j] = node
		quads[parent][i] = leaf
	}

	/// Post-order visit: every child before its parent.
	mutating func visitAfter(_ callback: (inout D3Quadtree, Int) -> Void) {
		guard root >= 0 else { return }
		var stack = [root]
		var next: [Int] = []
		while let q = stack.popLast() {
			if quads[q].isInternal {
				for c in 0..<4 {
					let child = quads[q][c]
					if child >= 0 { stack.append(child) }
				}
			}
			next.append(q)
		}
		while let q = next.popLast() {
			callback(&self, q)
		}
	}

	/// Pre-order visit (child 0 first); the callback returns true to skip
	/// a quad's children. Arguments: quad index, x0, y0, x1, y1.
	func visit(_ callback: (Int, Double, Double, Double, Double) -> Bool) {
		guard root >= 0 else { return }
		var stack: [(Int, Double, Double, Double, Double)] = [(root, x0, y0, x1, y1)]
		while let (q, x0, y0, x1, y1) = stack.popLast() {
			if !callback(q, x0, y0, x1, y1) && quads[q].isInternal {
				let xm = (x0 + x1) / 2
				let ym = (y0 + y1) / 2
				let node = quads[q]
				if node[3] >= 0 { stack.append((node[3], xm, ym, x1, y1)) }
				if node[2] >= 0 { stack.append((node[2], x0, ym, xm, y1)) }
				if node[1] >= 0 { stack.append((node[1], xm, y0, x1, ym)) }
				if node[0] >= 0 { stack.append((node[0], x0, y0, xm, ym)) }
			}
		}
	}

	subscript(q: Int) -> Quad {
		get { quads[q] }
		set { quads[q] = newValue }
	}

	func pointX(_ d: Int) -> Double { px[d] }
	func pointY(_ d: Int) -> Double { py[d] }
}
