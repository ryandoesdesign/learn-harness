import Foundation

// The typebox `Value.Check` / `Value.Convert` / `Value.Clean` subset the
// parse seams use (typebox 1.3, ported per schema kind). All three are pure
// here: typebox mutates in place, which is unobservable for the object
// roots every caller passes.

extension JSONSchema {
	/// `Value.Check`: JSON Schema validation over the supported keywords
	/// (type, const, enum, items, minItems, properties, required,
	/// additionalProperties, anyOf).
	public func check(_ value: JSONValue) -> Bool {
		switch kind {
		case .string:
			guard let s = value.stringValue else { return false }
			return minLength.map { s.jsLength >= $0 } ?? true
		case .boolean: return value.boolValue != nil
		case .number: return value.doubleValue?.isFinite == true
		case .integer: return value.doubleValue.map { $0.isFinite && $0 == $0.rounded(.towardZero) } == true
		case .null: return value.isNull
		case .literal(let c): return TypeboxTry.jsDeepEqual(c, value)
		case .enumeration(let values): return values.contains { TypeboxTry.jsDeepEqual($0, value) }
		case .array(let items, let minItems):
			guard let a = value.arrayValue else { return false }
			if let minItems, a.count < minItems { return false }
			return a.allSatisfy(items.check)
		case .object(let props, let additional):
			guard let o = value.objectValue else { return false }
			for p in props {
				if let v = o[p.name] {
					if !p.schema.check(v) { return false }
				} else if !p.schema.isOptional {
					return false
				}
			}
			if additional == false, o.keys.contains(where: { k in !props.contains { $0.name == k } }) { return false }
			return true
		case .union(let members): return members.contains { $0.check(value) }
		}
	}

	/// `Value.Convert`: coerce interior values where a reasonable conversion
	/// exists (`17` → `"17"` for a string, `"true"` → `true` for a boolean,
	/// a bare value → `[value]` for an array). Unconvertible values pass
	/// through for Check to reject.
	public func convert(_ value: JSONValue) -> JSONValue {
		switch kind {
		case .string: return TypeboxTry.string(value) ?? value
		case .boolean: return TypeboxTry.boolean(value) ?? value
		case .number: return TypeboxTry.number(value).map { .number(JSONNumber($0)) } ?? value
		case .integer: return TypeboxTry.number(value).map { .number(JSONNumber($0.rounded(.towardZero))) } ?? value
		case .null: return TypeboxTry.null(value) ?? value
		case .literal(let c):
			if TypeboxTry.jsDeepEqual(c, value) { return value }
			var converted: JSONValue?
			switch c {
			case .string: converted = TypeboxTry.string(value)
			case .bool: converted = TypeboxTry.boolean(value)
			case .number: converted = TypeboxTry.number(value).map { .number(JSONNumber($0)) }
			default: converted = .none
			}
			if let converted, TypeboxTry.jsDeepEqual(c, converted) { return converted }
			return value
		case .enumeration(let values):
			return JSONSchema.union(values.map { .literal($0) }).convert(value)
		case .array(let items, _):
			return .array((value.arrayValue ?? [value]).map(items.convert))
		case .object(let props, _):
			guard case .object(var o) = value else { return value }
			for p in props {
				if let v = o[p.name] { o[p.name] = p.schema.convert(v) }
			}
			return .object(o)
		case .union(let members):
			if members.contains(where: { $0.check(value) }) { return value }
			for m in members {
				let candidate = m.convert(value)
				if check(candidate) { return candidate }
			}
			return value
		}
	}

	/// `Value.Clean`: drop object keys the schema does not know (unless
	/// `additionalProperties: true`), recursively. Unions try members in
	/// declared order — typebox priority-sorts them first, which yields the
	/// same result for every union in use (none holds an object member).
	public func clean(_ value: JSONValue) -> JSONValue {
		switch kind {
		case .array(let items, _):
			guard let a = value.arrayValue else { return value }
			return .array(a.map(items.clean))
		case .object(let props, let additional):
			guard let o = value.objectValue else { return value }
			var out = JSONObject()
			for (k, v) in o {
				if let p = props.first(where: { $0.name == k }) {
					out[k] = p.schema.clean(v)
				} else if additional == true {
					out[k] = v
				}
			}
			return .object(out)
		case .union(let members):
			for m in members {
				let c = m.clean(value)
				if m.check(c) { return c }
			}
			return value
		default:
			return value
		}
	}
}

/// typebox's `Try*` coercions (value/convert/try): nil = Fail.
enum TypeboxTry {
	// (JSONValue is ExpressibleByNilLiteral: failures spell `.none` so no
	// literal `nil` can unify into `.null`.)
	static func string(_ v: JSONValue) -> JSONValue? {
		switch v {
		case .string: return v
		case .number(let n): return .string(jsNumberString(n.double))
		case .bool(let b): return .string(b ? "true" : "false")
		case .null: return .string("null")
		case .array, .object: return .none
		}
	}

	static func boolean(_ v: JSONValue) -> JSONValue? {
		switch v {
		case .bool: return v
		case .null: return false
		case .number(let n):
			if n.double == 0 { return .bool(false) }
			return n.double == 1 ? .bool(true) : .none
		case .string(let s):
			let lower = s.lowercased()
			if lower == "false" || s == "0" { return false }
			if lower == "true" || s == "1" { return true }
			return .none
		case .array, .object: return .none
		}
	}

	static func null(_ v: JSONValue) -> JSONValue? {
		switch v {
		case .null: return .null
		case .bool(let b): return b ? .none : .some(.null)
		case .number(let n): return n.double == 0 ? .some(.null) : .none
		case .string(let s):
			let lower = s.lowercased()
			return lower == "undefined" || lower == "null" || s.isEmpty || s == "0" ? .some(.null) : .none
		case .array, .object: return .none
		}
	}

	static func number(_ v: JSONValue) -> Double? {
		switch v {
		case .number(let n): return n.double
		case .bool(let b): return b ? 1 : 0
		case .null: return 0
		case .string(let s):
			let coerced = jsToNumber(s)
			if coerced.isFinite { return coerced }
			let lower = s.lowercased()
			if lower == "false" { return 0 }
			if lower == "true" { return 1 }
			// typebox's BigInt-literal form ("12n"), within the safe range.
			if s.wholeMatch(of: /-?(?:0|[1-9][0-9]*)n/) != nil, let i = Int(s.dropLast()), abs(i) <= 9_007_199_254_740_991 {
				return Double(i)
			}
			return .none
		case .array, .object: return .none
		}
	}

	/// JS `Number.prototype.toString()` (non-finite included).
	static func jsNumberString(_ d: Double) -> String {
		if d.isNaN { return "NaN" }
		if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
		return JSONNumber(d).lexeme
	}

	/// JS `String(value)` over JSON values.
	static func jsString(_ v: JSONValue) -> String {
		switch v {
		case .string(let s): s
		case .number(let n): jsNumberString(n.double)
		case .bool(let b): b ? "true" : "false"
		case .null: "null"
		case .array(let a): a.map { $0.isNull ? "" : jsString($0) }.joined(separator: ",")
		case .object: "[object Object]"
		}
	}

	/// JS `+string` (StringToNumber): NaN when not a numeric literal.
	static func jsToNumber(_ s: String) -> Double {
		let t = s.jsTrimmed
		if t.isEmpty { return 0 }
		switch t {
		case "Infinity", "+Infinity": return .infinity
		case "-Infinity": return -.infinity
		default: break
		}
		let lower = t.lowercased()
		for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
			let digits = t.dropFirst(2)
			guard !digits.isEmpty, let v = UInt64(digits, radix: radix) else { return .nan }
			return Double(v)
		}
		let decimal = /[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?/
		guard t.wholeMatch(of: decimal) != nil else { return .nan }
		return Double(t) ?? .nan
	}

	/// typebox `Guard.IsEqual` — deep structural equality, numbers by value.
	static func jsDeepEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
		switch (a, b) {
		case (.null, .null): return true
		case (.bool(let x), .bool(let y)): return x == y
		case (.number(let x), .number(let y)): return x.double == y.double
		case (.string(let x), .string(let y)): return x == y
		case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy(TypeboxTry.jsDeepEqual)
		case (.object(let x), .object(let y)):
			return x.count == y.count && x.allSatisfy { k, v in y[k].map { TypeboxTry.jsDeepEqual(v, $0) } ?? false }
		default: return false
		}
	}
}
