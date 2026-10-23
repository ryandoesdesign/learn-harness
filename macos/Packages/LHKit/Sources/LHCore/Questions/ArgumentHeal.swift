import Foundation

// Port of src/core/argument-heal.ts — the weak-model argument heal (the GLM
// incident, 2026-10-04: 19 rejected calls carrying `"mode": "\"recall\""`).
// Shared by the agent boundary (before validation) and the display parse
// (the record keeps RAW arguments, so the same wobble heals on read).

/// The literal values a property accepts ([] when it is not a literal union
/// or bare literal).
private func literalsOf(_ prop: JSONSchema) -> [JSONValue] {
	switch prop.kind {
	case .union(let members): members.flatMap(literalsOf)
	case .literal(let c): [c]
	default: []
	}
}

/// Does the property accept null (standalone or as a union member)?
private func acceptsNull(_ prop: JSONSchema) -> Bool {
	if prop.jsonType == "null" { return true }
	if case .union(let members) = prop.kind { return members.contains { $0.jsonType == "null" } }
	return false
}

/// JS `Array.prototype.includes` over primitive literals (objects never
/// match: JS compares them by reference).
private func includesLiteral(_ literals: [JSONValue], _ v: JSONValue) -> Bool {
	switch v {
	case .array, .object: false
	default: literals.contains { TypeboxTry.jsDeepEqual($0, v) }
	}
}

/// A STRING value where the schema expects a literal union / boolean / null
/// / number / array is JSON-parsed and kept when the parsed value satisfies
/// the expectation. Well-formed args come back unchanged; unhealable values
/// stay for validation to reject honestly.
public func healEncodedArguments(_ args: JSONValue, schema: JSONSchema) -> JSONValue {
	guard case .object(var healed) = args else { return args }
	let properties = schema.properties
	if properties.isEmpty { return args }
	for p in properties {
		guard case .string(let raw)? = healed[p.name] else { continue }
		let prop = p.schema
		let parsed = JSONValue.tryParse(raw)
		var fixed: JSONValue?
		let literals = literalsOf(prop)
		if !literals.isEmpty {
			if includesLiteral(literals, .string(raw)) { continue }
			if let parsed, includesLiteral(literals, parsed) { fixed = parsed }
		}
		// Null carries no const — a literal ∪ null union must also accept "null".
		if fixed == .none, acceptsNull(prop), parsed?.isNull == true { fixed = .null }
		if fixed == .none, prop.jsonType == "boolean", let parsed, parsed.boolValue != nil { fixed = parsed }
		if fixed == .none, prop.jsonType == "number" || prop.jsonType == "integer", let parsed, case .number = parsed { fixed = parsed }
		if fixed == .none, prop.jsonType == "array", let parsed, parsed.arrayValue != nil { fixed = parsed }
		if let fixed { healed[p.name] = fixed }
	}
	return .object(healed)
}
