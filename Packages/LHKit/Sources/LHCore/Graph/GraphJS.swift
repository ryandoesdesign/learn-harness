import Foundation

/// The JS ordering semantics the graph ports depend on (graph.ts sorts with
/// `<` on strings, default `sort()`, and `localeCompare`).
enum GraphJS {
	/// JS `a < b` on strings: UTF-16 code-unit order.
	static func less(_ a: String, _ b: String) -> Bool {
		a.utf16.lexicographicallyPrecedes(b.utf16)
	}

	/// `[...xs].sort()` with no comparator: code-unit order.
	static func sorted(_ xs: [String]) -> [String] {
		stableSorted(xs) { less($0, $1) ? -1 : less($1, $0) ? 1 : 0 }
	}

	/// `a.localeCompare(b)` — the ICU collation node uses (Foundation's
	/// locale compare reproduces it: punctuation < digits < letters, case
	/// second, lowercase first).
	static func localeCompare(_ a: String, _ b: String) -> Int {
		switch a.compare(b, options: [], range: nil, locale: collationLocale) {
		case .orderedAscending: -1
		case .orderedDescending: 1
		case .orderedSame: 0
		}
	}

	private static let collationLocale = Locale(identifier: "en")

	/// `Array.prototype.sort(cmp)` — stable, comparator returns <0 / 0 / >0.
	static func stableSorted<T>(_ xs: [T], by cmp: (T, T) -> Int) -> [T] {
		xs.enumerated()
			.sorted { l, r in
				let c = cmp(l.element, r.element)
				return c != 0 ? c < 0 : l.offset < r.offset
			}
			.map(\.element)
	}

	/// `new Date(ms).toISOString()` (years 0…9999).
	static func isoString(_ date: Date) -> String {
		let ms = Int((date.timeIntervalSince1970 * 1000).rounded(.down))
		var days = ms >= 0 ? ms / 86_400_000 : (ms - 86_399_999) / 86_400_000
		let msOfDay = ms - days * 86_400_000
		// Civil-from-days (H. Hinnant).
		days += 719_468
		let era = (days >= 0 ? days : days - 146_096) / 146_097
		let doe = days - era * 146_097
		let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
		let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
		let mp = (5 * doy + 2) / 153
		let d = doy - (153 * mp + 2) / 5 + 1
		let m = mp < 10 ? mp + 3 : mp - 9
		let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
		func pad(_ v: Int, _ n: Int) -> String {
			let s = String(v)
			return String(repeating: "0", count: Swift.max(0, n - s.count)) + s
		}
		let h = msOfDay / 3_600_000, mi = msOfDay / 60_000 % 60, s = msOfDay / 1000 % 60, f = msOfDay % 1000
		return "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(h, 2)):\(pad(mi, 2)):\(pad(s, 2)).\(pad(f, 3))Z"
	}

	/// Lowercase hex of bytes (`Buffer.toString("hex")`).
	static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
		let digits = Array("0123456789abcdef".utf8)
		var out: [UInt8] = []
		for b in bytes {
			out.append(digits[Int(b >> 4)])
			out.append(digits[Int(b & 0x0F)])
		}
		return String(decoding: out, as: UTF8.self)
	}
}

/// Injectable randomness for id minting (TS `randomBytes`).
public struct GraphRandom: Sendable {
	public var bytes: @Sendable (Int) -> [UInt8]
	public init(bytes: @escaping @Sendable (Int) -> [UInt8]) { self.bytes = bytes }

	/// The system CSPRNG.
	public static let system = GraphRandom { n in
		var g = SystemRandomNumberGenerator()
		return (0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) }
	}
}
