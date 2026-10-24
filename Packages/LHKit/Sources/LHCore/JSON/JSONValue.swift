import Foundation

/// A JSON value that round-trips byte-for-byte with JavaScript's
/// `JSON.stringify` — the record's "bytes untouched" law (native-macos-plan,
/// preserved thinking). Objects keep insertion order and numbers keep their
/// source lexeme, so `parse(s).serialized() == s` for any compact JSON a JS
/// engine wrote.
public enum JSONValue: Sendable, Hashable {
	case null
	case bool(Bool)
	case number(JSONNumber)
	case string(String)
	case array([JSONValue])
	case object(JSONObject)
}

/// A JSON number that remembers how it was written.
public struct JSONNumber: Sendable, Hashable {
	public let lexeme: String
	public var double: Double { Double(lexeme) ?? .nan }

	public init(lexeme: String) { self.lexeme = lexeme }

	/// JS number formatting (`String(n)` / `JSON.stringify`): integral values
	/// print without a fraction, others with the shortest round-trip form.
	public init(_ value: Double) {
		self.lexeme = JSONNumber.jsFormat(value)
	}

	public init(_ value: Int) { self.lexeme = String(value) }

	static func jsFormat(_ value: Double) -> String {
		guard value.isFinite else { return "null" }
		if value == 0 { return "0" }
		if value == value.rounded(), abs(value) < 1e21 {
			return String(format: "%.0f", value)
		}
		// Swift's description is shortest round-trip; normalise the exponent
		// spelling to JS ("1e-7", "1.5e+21").
		var s = "\(value)"
		if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
			var mantissa = String(s[..<e])
			var exponent = String(s[s.index(after: e)...])
			if mantissa.hasSuffix(".0") { mantissa.removeLast(2) }
			var sign = "+"
			if exponent.hasPrefix("-") { sign = "-"; exponent.removeFirst() } else if exponent.hasPrefix("+") { exponent.removeFirst() }
			while exponent.count > 1 && exponent.hasPrefix("0") { exponent.removeFirst() }
			s = "\(mantissa)e\(sign)\(exponent)"
		}
		return s
	}
}

/// An insertion-ordered JSON object. Duplicate keys follow JS semantics: the
/// last assignment wins, but the key keeps its first position.
public struct JSONObject: Sendable, Hashable, Sequence {
	public private(set) var keys: [String] = []
	private var storage: [String: JSONValue] = [:]

	public init() {}

	public init(_ pairs: KeyValuePairs<String, JSONValue>) {
		for (k, v) in pairs { self[k] = v }
	}

	public init(pairs: [(String, JSONValue)]) {
		for (k, v) in pairs { self[k] = v }
	}

	public subscript(key: String) -> JSONValue? {
		get { storage[key] }
		set {
			if let newValue {
				if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
			} else if storage.removeValue(forKey: key) != nil {
				keys.removeAll { $0 == key }
			}
		}
	}

	public var count: Int { keys.count }
	public var isEmpty: Bool { keys.isEmpty }

	public func makeIterator() -> AnyIterator<(key: String, value: JSONValue)> {
		var i = 0
		return AnyIterator {
			guard i < keys.count else { return nil }
			defer { i += 1 }
			let k = keys[i]
			return (k, storage[k]!)
		}
	}

	public static func == (a: JSONObject, b: JSONObject) -> Bool {
		a.keys == b.keys && a.storage == b.storage
	}

	public func hash(into hasher: inout Hasher) {
		hasher.combine(keys)
		for k in keys { hasher.combine(storage[k]) }
	}
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
	ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
	public init(nilLiteral: ()) { self = .null }
	public init(booleanLiteral value: Bool) { self = .bool(value) }
	public init(integerLiteral value: Int) { self = .number(JSONNumber(value)) }
	public init(floatLiteral value: Double) { self = .number(JSONNumber(value)) }
	public init(stringLiteral value: String) { self = .string(value) }
	public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
	public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(pairs: elements)) }
}

// MARK: - Accessors (JS-flavoured reads: wrong type → nil, never throw)

extension JSONValue {
	public static func number(_ d: Double) -> JSONValue { .number(JSONNumber(d)) }
	public static func number(_ i: Int) -> JSONValue { .number(JSONNumber(i)) }

	public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
	public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
	public var doubleValue: Double? { if case .number(let n) = self { return n.double }; return nil }
	public var intValue: Int? {
		guard let d = doubleValue, d.isFinite, d == d.rounded(), abs(d) < 9.0e15 else { return nil }
		return Int(d)
	}
	public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
	public var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
	public var isNull: Bool { if case .null = self { return true }; return false }

	/// nil for JSON null (JS `v ?? undefined`). Use this instead of a
	/// `v.isNull ? nil : v` ternary — JSONValue is ExpressibleByNilLiteral,
	/// so that `nil` silently becomes `.null`.
	public var nonNull: JSONValue? { isNull ? Optional<JSONValue>.none : self }

	/// `value[key]` on an object; nil on anything else (JS optional chaining).
	public subscript(key: String) -> JSONValue? {
		get { objectValue?[key] }
		set {
			guard case .object(var o) = self else { return }
			o[key] = newValue
			self = .object(o)
		}
	}

	/// `value[i]` on an array; nil when out of range or not an array.
	public subscript(index: Int) -> JSONValue? {
		guard case .array(let a) = self, a.indices.contains(index) else { return nil }
		return a[index]
	}

	/// JS truthiness (`!!value`).
	public var isTruthy: Bool {
		switch self {
		case .null: return false
		case .bool(let b): return b
		case .number(let n): let d = n.double; return !(d == 0 || d.isNaN)
		case .string(let s): return !s.isEmpty
		case .array, .object: return true
		}
	}

	/// JS `typeof` for JSON values.
	public var jsTypeof: String {
		switch self {
		case .null: return "object"
		case .bool: return "boolean"
		case .number: return "number"
		case .string: return "string"
		case .array, .object: return "object"
		}
	}
}
