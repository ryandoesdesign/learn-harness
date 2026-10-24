import Foundation

/// JavaScript string semantics for ports that must match the TS outputs:
/// JS strings index by UTF-16 code unit, Swift's by grapheme cluster.
extension String {
	/// `s.length`.
	public var jsLength: Int { utf16.count }

	/// `s.slice(start, end)` with JS negative-index and clamping rules.
	public func jsSlice(_ start: Int, _ end: Int? = nil) -> String {
		let n = utf16.count
		func norm(_ i: Int) -> Int { i < 0 ? Swift.max(0, n + i) : Swift.min(i, n) }
		let s = norm(start)
		let e = end.map(norm) ?? n
		guard s < e else { return "" }
		let u = Array(utf16)
		return String(decoding: u[s..<e], as: UTF16.self)
	}

	/// `s.trim()` — JS whitespace (incl. U+FEFF and line terminators).
	public var jsTrimmed: String {
		trimmingCharacters(in: .jsWhitespace)
	}
}

extension CharacterSet {
	/// ECMAScript WhiteSpace + LineTerminator.
	public static let jsWhitespace: CharacterSet = {
		var set = CharacterSet(charactersIn: "\u{09}\u{0B}\u{0C}\u{20}\u{A0}\u{FEFF}\u{0A}\u{0D}\u{2028}\u{2029}")
		set.insert(charactersIn: "\u{1680}")
		set.insert(charactersIn: Unicode.Scalar(0x2000)!...Unicode.Scalar(0x200A)!)
		set.insert(charactersIn: "\u{202F}\u{205F}\u{3000}")
		return set
	}()
}
