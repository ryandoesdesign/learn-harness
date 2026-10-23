import Foundation

// Bit-exact ports of the V8 `Math` functions the layout uses. Darwin's libm
// is accurate but rounds differently from V8 in a few percent of cases, and
// a force simulation amplifies one-ulp differences. V8's `Math.sin`,
// `Math.cos` and `Math.atan2` are fdlibm (v8/src/base/ieee754.cc), and
// `Math.hypot` is the scaled Kahan sum in v8/src/builtins/math.tq.
// `Math.sqrt` is IEEE-exact on both sides, so it needs no port.
//
// Range: the trig reduction covers |x| <= 2^19·π/2 (fdlibm's "medium" path).
// Larger arguments fall back to Darwin libm, so there they are no longer
// bit-exact. The layout's angles stay far below that bound.

enum JSMath {
	// MARK: - Bit helpers

	@inline(__always) private static func high(_ x: Double) -> Int32 {
		Int32(truncatingIfNeeded: x.bitPattern >> 32)
	}

	@inline(__always) private static func low(_ x: Double) -> UInt32 {
		UInt32(truncatingIfNeeded: x.bitPattern)
	}

	@inline(__always) private static func fromWords(_ hi: UInt32, _ lo: UInt32) -> Double {
		Double(bitPattern: UInt64(hi) << 32 | UInt64(lo))
	}

	/// `a·b + c` with one rounding: clang's default `-ffp-contract=on` fuses
	/// every `a*b ± c` inside one C expression into `llvm.fmuladd`, which is
	/// an FMA on arm64. V8's fdlibm is built that way, so each fused site
	/// below mirrors one such C expression (the LHS product wins when both
	/// operands are products, as in clang's tryEmitFMulAdd).
	@inline(__always) private static func fma(_ a: Double, _ b: Double, _ c: Double) -> Double {
		c.addingProduct(a, b)
	}

	// MARK: - Math.hypot (two arguments)

	static func hypot(_ a: Double, _ b: Double) -> Double {
		if a.isNaN || b.isNaN {
			// V8 checks infinity first: hypot(NaN, ±∞) = ∞.
			return a.isInfinite || b.isInfinite ? .infinity : .nan
		}
		let x = Swift.abs(a)
		let y = Swift.abs(b)
		var max = 0.0
		if x > max { max = x }
		if y > max { max = y }
		if max == .infinity { return .infinity }
		if max == 0 { return 0 }
		var sum = 0.0
		var compensation = 0.0
		for v in [x, y] {
			let n = v / max
			let summand = n * n - compensation
			let preliminary = sum + summand
			compensation = (preliminary - sum) - summand
			sum = preliminary
		}
		return sum.squareRoot() * max
	}

	// MARK: - Trig kernels

	private static let S1 = -1.66666666666666324348e-01
	private static let S2 = 8.33333333332248946124e-03
	private static let S3 = -1.98412698298579493134e-04
	private static let S4 = 2.75573137070700676789e-06
	private static let S5 = -2.50507602534068634195e-08
	private static let S6 = 1.58969099521155010221e-10

	private static func kernelSin(_ x: Double, _ y: Double, _ iy: Int) -> Double {
		let ix = high(x) & 0x7FFF_FFFF
		if ix < 0x3E40_0000 {
			if Int(x) == 0 { return x }
		}
		let z = x * x
		let v = z * x
		let r = fma(z, fma(z, fma(z, fma(z, S6, S5), S4), S3), S2)
		if iy == 0 {
			return fma(v, fma(z, r, S1), x)
		}
		return x - fma(-v, S1, fma(z, fma(0.5, y, -(v * r)), -y))
	}

	private static let C1 = 4.16666666666666019037e-02
	private static let C2 = -1.38888888888741095749e-03
	private static let C3 = 2.48015872894767294178e-05
	private static let C4 = -2.75573143513906633035e-07
	private static let C5 = 2.08757232129817482790e-09
	private static let C6 = -1.13596475577881948265e-11

	private static func kernelCos(_ x: Double, _ y: Double) -> Double {
		let ix = high(x) & 0x7FFF_FFFF
		if ix < 0x3E40_0000 {
			if Int(x) == 0 { return 1 }
		}
		let z = x * x
		let r = z * fma(z, fma(z, fma(z, fma(z, fma(z, C6, C5), C4), C3), C2), C1)
		if ix < 0x3FD3_3333 {
			return 1 - fma(0.5, z, -fma(z, r, -(x * y)))
		}
		let qx: Double
		if ix > 0x3FE9_0000 {
			qx = 0.28125
		} else {
			qx = fromWords(UInt32(bitPattern: ix - 0x0020_0000), 0)
		}
		let iz = fma(0.5, z, -qx)
		let a = 1 - qx
		return a - (iz - fma(z, r, -(x * y)))
	}

	private static let npio2hw: [Int32] = [
		0x3FF9_21FB, 0x4009_21FB, 0x4012_D97C, 0x4019_21FB, 0x401F_6A7A, 0x4022_D97C,
		0x4025_FDBB, 0x4029_21FB, 0x402C_463A, 0x402F_6A7A, 0x4031_475C, 0x4032_D97C,
		0x4034_6B9C, 0x4035_FDBB, 0x4037_8FDB, 0x4039_21FB, 0x403A_B41B, 0x403C_463A,
		0x403D_D85A, 0x403F_6A7A, 0x4040_7E4C, 0x4041_475C, 0x4042_106C, 0x4042_D97C,
		0x4043_A28C, 0x4044_6B9C, 0x4045_34AC, 0x4045_FDBB, 0x4046_C6CB, 0x4047_8FDB,
		0x4048_58EB, 0x4049_21FB,
	]
	private static let invpio2 = 6.36619772367581382433e-01
	private static let pio2_1 = 1.57079632673412561417e+00
	private static let pio2_1t = 6.07710050650619224932e-11
	private static let pio2_2 = 6.07710050630396597660e-11
	private static let pio2_2t = 2.02226624879595063154e-21
	private static let pio2_3 = 2.02226624871116645580e-21
	private static let pio2_3t = 8.47842766036889956997e-32

	/// fdlibm __ieee754_rem_pio2 for |x| <= 2^19·π/2; nil beyond that.
	private static func remPio2(_ x: Double) -> (n: Int32, y0: Double, y1: Double)? {
		let hx = high(x)
		let ix = hx & 0x7FFF_FFFF
		if ix <= 0x3FE9_21FB { return (0, x, 0) }
		if ix < 0x4002_D97C {
			if hx > 0 {
				var z = x - pio2_1
				if ix != 0x3FF9_21FB {
					let y0 = z - pio2_1t
					return (1, y0, (z - y0) - pio2_1t)
				}
				z -= pio2_2
				let y0 = z - pio2_2t
				return (1, y0, (z - y0) - pio2_2t)
			} else {
				var z = x + pio2_1
				if ix != 0x3FF9_21FB {
					let y0 = z + pio2_1t
					return (-1, y0, (z - y0) + pio2_1t)
				}
				z += pio2_2
				let y0 = z + pio2_2t
				return (-1, y0, (z - y0) + pio2_2t)
			}
		}
		guard ix <= 0x4139_21FB else { return nil }
		var t = Swift.abs(x)
		let n = Int32(fma(t, invpio2, 0.5))
		let fn = Double(n)
		var r = fma(-fn, pio2_1, t)
		var w = fn * pio2_1t
		var y0: Double
		if n < 32 && ix != npio2hw[Int(n) - 1] {
			y0 = r - w
		} else {
			let j = ix >> 20
			y0 = r - w
			var i = j - ((high(y0) >> 20) & 0x7FF)
			if i > 16 {
				t = r
				w = fn * pio2_2
				r = t - w
				w = fma(fn, pio2_2t, -((t - r) - w))
				y0 = r - w
				i = j - ((high(y0) >> 20) & 0x7FF)
				if i > 49 {
					t = r
					w = fn * pio2_3
					r = t - w
					w = fma(fn, pio2_3t, -((t - r) - w))
					y0 = r - w
				}
			}
		}
		let y1 = (r - y0) - w
		if hx < 0 { return (-n, -y0, -y1) }
		return (n, y0, y1)
	}

	// MARK: - Math.sin / Math.cos

	static func sin(_ x: Double) -> Double {
		let ix = high(x) & 0x7FFF_FFFF
		if ix <= 0x3FE9_21FB { return kernelSin(x, 0, 0) }
		if ix >= 0x7FF0_0000 { return x - x }
		guard let (n, y0, y1) = remPio2(x) else { return Foundation.sin(x) }
		switch n & 3 {
		case 0: return kernelSin(y0, y1, 1)
		case 1: return kernelCos(y0, y1)
		case 2: return -kernelSin(y0, y1, 1)
		default: return -kernelCos(y0, y1)
		}
	}

	static func cos(_ x: Double) -> Double {
		let ix = high(x) & 0x7FFF_FFFF
		if ix <= 0x3FE9_21FB { return kernelCos(x, 0) }
		if ix >= 0x7FF0_0000 { return x - x }
		guard let (n, y0, y1) = remPio2(x) else { return Foundation.cos(x) }
		switch n & 3 {
		case 0: return kernelCos(y0, y1)
		case 1: return -kernelSin(y0, y1, 1)
		case 2: return -kernelCos(y0, y1)
		default: return kernelSin(y0, y1, 1)
		}
	}

	// MARK: - Math.atan / Math.atan2

	private static let atanhi: [Double] = [
		4.63647609000806093515e-01,
		7.85398163397448278999e-01,
		9.82793723247329054082e-01,
		1.57079632679489655800e+00,
	]
	private static let atanlo: [Double] = [
		2.26987774529616870924e-17,
		3.06161699786838301793e-17,
		1.39033110312309984516e-17,
		6.12323399573676603587e-17,
	]
	private static let aT: [Double] = [
		3.33333333333329318027e-01,
		-1.99999999998764832476e-01,
		1.42857142725034663711e-01,
		-1.11111104054623557880e-01,
		9.09088713343650656196e-02,
		-7.69187620504482999495e-02,
		6.66107313738753120669e-02,
		-5.83357013379057348645e-02,
		4.97687799461593236017e-02,
		-3.65315727442169155270e-02,
		1.62858201153657823623e-02,
	]

	static func atan(_ input: Double) -> Double {
		var x = input
		let hx = high(x)
		let ix = hx & 0x7FFF_FFFF
		if ix >= 0x4410_0000 {
			if ix > 0x7FF0_0000 || (ix == 0x7FF0_0000 && low(x) != 0) { return x + x }
			return hx > 0 ? atanhi[3] + atanlo[3] : -atanhi[3] - atanlo[3]
		}
		var id: Int
		if ix < 0x3FDC_0000 {
			if ix < 0x3E40_0000 { return x }
			id = -1
		} else {
			x = Swift.abs(x)
			if ix < 0x3FF3_0000 {
				if ix < 0x3FE6_0000 {
					id = 0
					x = fma(2.0, x, -1) / (2.0 + x)
				} else {
					id = 1
					x = (x - 1) / (x + 1)
				}
			} else {
				if ix < 0x4003_8000 {
					id = 2
					x = (x - 1.5) / fma(1.5, x, 1)
				} else {
					id = 3
					x = -1.0 / x
				}
			}
		}
		let z = x * x
		let w = z * z
		let s1 = z * fma(w, fma(w, fma(w, fma(w, fma(w, aT[10], aT[8]), aT[6]), aT[4]), aT[2]), aT[0])
		let s2 = w * fma(w, fma(w, fma(w, fma(w, aT[9], aT[7]), aT[5]), aT[3]), aT[1])
		if id < 0 {
			return fma(-x, s1 + s2, x)
		}
		let r = atanhi[id] - (fma(x, s1 + s2, -atanlo[id]) - x)
		return hx < 0 ? -r : r
	}

	private static let pi_o_4 = 7.8539816339744827900e-01
	private static let pi_o_2 = 1.5707963267948965580e+00
	private static let pi = 3.1415926535897931160e+00
	private static let pi_lo = 1.2246467991473531772e-16

	static func atan2(_ y: Double, _ x: Double) -> Double {
		if x.isNaN || y.isNaN { return x + y }
		let hx = high(x)
		let ix = hx & 0x7FFF_FFFF
		let lx = low(x)
		let hy = high(y)
		let iy = hy & 0x7FFF_FFFF
		let ly = low(y)
		if hx == 0x3FF0_0000 && lx == 0 { return atan(y) }
		var m = Int((hy >> 31) & 1) | Int((hx >> 30) & 2)
		// (`± tiny` terms in fdlibm only raise inexact; they round away.)
		if iy == 0 && ly == 0 {
			switch m {
			case 0, 1: return y
			case 2: return pi
			default: return -pi
			}
		}
		if ix == 0 && lx == 0 { return hy < 0 ? -pi_o_2 : pi_o_2 }
		if ix == 0x7FF0_0000 {
			if iy == 0x7FF0_0000 {
				switch m {
				case 0: return pi_o_4
				case 1: return -pi_o_4
				case 2: return 3.0 * pi_o_4
				default: return -3.0 * pi_o_4
				}
			}
			switch m {
			case 0: return 0
			case 1: return -0.0
			case 2: return pi
			default: return -pi
			}
		}
		if iy == 0x7FF0_0000 { return hy < 0 ? -pi_o_2 : pi_o_2 }
		let k = (iy - ix) >> 20
		let z: Double
		if k > 60 {
			z = pi_o_2 + 0.5 * pi_lo
			m &= 1
		} else if hx < 0 && k < -60 {
			z = 0
		} else {
			z = atan(Swift.abs(y / x))
		}
		switch m {
		case 0: return z
		case 1: return -z
		case 2: return pi - (z - pi_lo)
		default: return (z - pi_lo) - pi
		}
	}
}
