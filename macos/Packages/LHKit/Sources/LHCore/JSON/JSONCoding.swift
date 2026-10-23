import Foundation

public struct JSONParseError: Error, Sendable, CustomStringConvertible {
	public let offset: Int
	public let message: String
	public var description: String { "JSON parse error at \(offset): \(message)" }
}

// MARK: - Parsing (JSON.parse)

extension JSONValue {
	public static func parse(_ text: String) throws -> JSONValue {
		try parse(Data(text.utf8))
	}

	public static func parse(_ data: Data) throws -> JSONValue {
		var p = JSONParser(bytes: [UInt8](data))
		p.skipWhitespace()
		let v = try p.parseValue()
		p.skipWhitespace()
		guard p.i == p.bytes.count else { throw p.error("unexpected trailing content") }
		return v
	}

	/// `JSON.parse` that yields nil instead of throwing.
	public static func tryParse(_ text: String) -> JSONValue? { try? parse(text) }
}

private struct JSONParser {
	let bytes: [UInt8]
	var i = 0

	init(bytes: [UInt8]) { self.bytes = bytes }

	func error(_ m: String) -> JSONParseError { JSONParseError(offset: i, message: m) }

	mutating func skipWhitespace() {
		while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
	}

	mutating func parseValue() throws -> JSONValue {
		guard i < bytes.count else { throw error("unexpected end") }
		switch bytes[i] {
		case UInt8(ascii: "{"): return try parseObject()
		case UInt8(ascii: "["): return try parseArray()
		case UInt8(ascii: "\""): return .string(try parseString())
		case UInt8(ascii: "t"): try expect("true"); return .bool(true)
		case UInt8(ascii: "f"): try expect("false"); return .bool(false)
		case UInt8(ascii: "n"): try expect("null"); return .null
		default: return .number(try parseNumber())
		}
	}

	mutating func expect(_ word: String) throws {
		let w = Array(word.utf8)
		guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw error("expected \(word)") }
		i += w.count
	}

	mutating func parseObject() throws -> JSONValue {
		i += 1
		var obj = JSONObject()
		skipWhitespace()
		if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
		while true {
			skipWhitespace()
			guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected key") }
			let key = try parseString()
			skipWhitespace()
			guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("expected :") }
			i += 1
			skipWhitespace()
			obj[key] = try parseValue()
			skipWhitespace()
			guard i < bytes.count else { throw error("unterminated object") }
			if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
			if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
			throw error("expected , or }")
		}
	}

	mutating func parseArray() throws -> JSONValue {
		i += 1
		var arr: [JSONValue] = []
		skipWhitespace()
		if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
		while true {
			skipWhitespace()
			arr.append(try parseValue())
			skipWhitespace()
			guard i < bytes.count else { throw error("unterminated array") }
			if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
			if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
			throw error("expected , or ]")
		}
	}

	mutating func parseNumber() throws -> JSONNumber {
		let start = i
		if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
		func digits() -> Int { let s = i; while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }; return i - s }
		guard digits() > 0 else { throw error("bad number") }
		if i < bytes.count, bytes[i] == UInt8(ascii: ".") { i += 1; guard digits() > 0 else { throw error("bad fraction") } }
		if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
			i += 1
			if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
			guard digits() > 0 else { throw error("bad exponent") }
		}
		return JSONNumber(lexeme: String(decoding: bytes[start..<i], as: UTF8.self))
	}

	mutating func parseHex4() throws -> UInt16 {
		guard i + 4 <= bytes.count, let v = UInt16(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else {
			throw error("bad \\u escape")
		}
		i += 4
		return v
	}

	mutating func parseString() throws -> String {
		i += 1
		var units: [UInt16] = []
		var runStart = i
		func flushRun(_ end: Int) { units.append(contentsOf: String(decoding: bytes[runStart..<end], as: UTF8.self).utf16) }
		while true {
			guard i < bytes.count else { throw error("unterminated string") }
			let b = bytes[i]
			if b == UInt8(ascii: "\"") { flushRun(i); i += 1; break }
			if b == UInt8(ascii: "\\") {
				flushRun(i)
				i += 1
				guard i < bytes.count else { throw error("bad escape") }
				let e = bytes[i]
				i += 1
				switch e {
				case UInt8(ascii: "\""): units.append(0x22)
				case UInt8(ascii: "\\"): units.append(0x5C)
				case UInt8(ascii: "/"): units.append(0x2F)
				case UInt8(ascii: "b"): units.append(0x08)
				case UInt8(ascii: "f"): units.append(0x0C)
				case UInt8(ascii: "n"): units.append(0x0A)
				case UInt8(ascii: "r"): units.append(0x0D)
				case UInt8(ascii: "t"): units.append(0x09)
				case UInt8(ascii: "u"): units.append(try parseHex4())
				default: throw error("bad escape")
				}
				runStart = i
				continue
			}
			i += 1
		}
		return String(decoding: units, as: UTF16.self)
	}
}

// MARK: - Serialising (JSON.stringify)

extension JSONValue {
	/// `JSON.stringify(value)`; with `indent`, `JSON.stringify(value, null, indent)`.
	public func serialized(indent: Int = 0) -> String {
		serialized(indentUnit: String(repeating: " ", count: Swift.max(0, Swift.min(indent, 10))))
	}

	/// `JSON.stringify(value, null, unit)` with a string indent (e.g. "\t").
	public func serialized(indentUnit: String) -> String {
		var out = ""
		write(to: &out, unit: indentUnit, depth: 0)
		return out
	}

	public var serializedData: Data { Data(serialized().utf8) }

	private func write(to out: inout String, unit: String, depth: Int) {
		let pretty = !unit.isEmpty
		switch self {
		case .null: out += "null"
		case .bool(let b): out += b ? "true" : "false"
		case .number(let n): out += n.lexeme
		case .string(let s): JSONValue.writeString(s, to: &out)
		case .array(let a):
			if a.isEmpty { out += "[]"; return }
			out += "["
			for (k, v) in a.enumerated() {
				if k > 0 { out += "," }
				if pretty { out += "\n" + String(repeating: unit, count: depth + 1) }
				v.write(to: &out, unit: unit, depth: depth + 1)
			}
			if pretty { out += "\n" + String(repeating: unit, count: depth) }
			out += "]"
		case .object(let o):
			if o.isEmpty { out += "{}"; return }
			out += "{"
			var first = true
			for (k, v) in o {
				if !first { out += "," }
				first = false
				if pretty { out += "\n" + String(repeating: unit, count: depth + 1) }
				JSONValue.writeString(k, to: &out)
				out += pretty ? ": " : ":"
				v.write(to: &out, unit: unit, depth: depth + 1)
			}
			if pretty { out += "\n" + String(repeating: unit, count: depth) }
			out += "}"
		}
	}

	/// JS string quoting (`JSON.stringify("…")`).
	public static func quote(_ s: String) -> String {
		var out = ""
		writeString(s, to: &out)
		return out
	}

	private static func writeString(_ s: String, to out: inout String) {
		out += "\""
		for scalar in s.unicodeScalars {
			switch scalar {
			case "\"": out += "\\\""
			case "\\": out += "\\\\"
			case "\u{08}": out += "\\b"
			case "\u{0C}": out += "\\f"
			case "\n": out += "\\n"
			case "\r": out += "\\r"
			case "\t": out += "\\t"
			default:
				if scalar.value < 0x20 {
					out += String(format: "\\u%04x", scalar.value)
				} else {
					out.unicodeScalars.append(scalar)
				}
			}
		}
		out += "\""
	}
}

// MARK: - Codable bridge

extension JSONValue: Codable {
	public init(from decoder: Decoder) throws {
		let c = try decoder.singleValueContainer()
		if c.decodeNil() { self = .null; return }
		if let b = try? c.decode(Bool.self) { self = .bool(b); return }
		if let d = try? c.decode(Double.self) { self = .number(JSONNumber(d)); return }
		if let s = try? c.decode(String.self) { self = .string(s); return }
		if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
		let dict = try c.decode([String: JSONValue].self)
		self = .object(JSONObject(pairs: dict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.singleValueContainer()
		switch self {
		case .null: try c.encodeNil()
		case .bool(let b): try c.encode(b)
		case .number(let n): try c.encode(n.double)
		case .string(let s): try c.encode(s)
		case .array(let a): try c.encode(a)
		case .object(let o): try c.encode(Dictionary(uniqueKeysWithValues: o.map { ($0.key, $0.value) }))
		}
	}
}
