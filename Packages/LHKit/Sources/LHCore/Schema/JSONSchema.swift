import Foundation

/// The in-house stand-in for the typebox schemas (docs/native-macos-m1.md,
/// "Schemas"): exactly the subset the tool contracts use. `json` yields the
/// JSON Schema object typebox emits (same keys, same order); the same value
/// is sent to the API in M3. Validation/coercion live in JSONSchemaValue.swift.
public struct JSONSchema: Sendable, Hashable {
	public indirect enum Kind: Sendable, Hashable {
		case string, boolean, number, integer, null
		/// `Type.Literal` — a string / number / boolean constant.
		case literal(JSONValue)
		/// `Type.Enum` — emitted as `{enum: [...]}`.
		case enumeration([JSONValue])
		case array(items: JSONSchema, minItems: Int?)
		case object(properties: [Property], additionalProperties: Bool?)
		/// `Type.Union` — `anyOf`.
		case union([JSONSchema])
	}

	public struct Property: Sendable, Hashable {
		public var name: String
		public var schema: JSONSchema
		public init(_ name: String, _ schema: JSONSchema) {
			self.name = name
			self.schema = schema
		}
	}

	public var kind: Kind
	public var description: String?
	/// `Type.Optional` — the key is left out of the parent's `required`.
	public var isOptional: Bool
	/// `Type.String({minLength})` — strings only.
	public var minLength: Int?
	/// `Type.Integer({minimum})` / `Type.Number({minimum})`.
	public var minimum: Double?

	public init(_ kind: Kind, description: String? = nil, isOptional: Bool = false) {
		self.kind = kind
		self.description = description
		self.isOptional = isOptional
	}
}

// MARK: - Builders (typebox's Type.* spelling)

extension JSONSchema {
	public static func string(description: String? = nil) -> JSONSchema { JSONSchema(.string, description: description) }
	public static func integer(minimum: Double, description: String? = nil) -> JSONSchema {
		var s = JSONSchema(.integer, description: description)
		s.minimum = minimum
		return s
	}
	public static func string(minLength: Int, description: String? = nil) -> JSONSchema {
		var s = JSONSchema(.string, description: description)
		s.minLength = minLength
		return s
	}
	public static func boolean(description: String? = nil) -> JSONSchema { JSONSchema(.boolean, description: description) }
	public static func number(description: String? = nil) -> JSONSchema { JSONSchema(.number, description: description) }
	public static func integer(description: String? = nil) -> JSONSchema { JSONSchema(.integer, description: description) }
	public static func null(description: String? = nil) -> JSONSchema { JSONSchema(.null, description: description) }
	public static func literal(_ value: JSONValue, description: String? = nil) -> JSONSchema { JSONSchema(.literal(value), description: description) }
	public static func enumeration(_ values: [JSONValue], description: String? = nil) -> JSONSchema { JSONSchema(.enumeration(values), description: description) }
	public static func union(_ members: [JSONSchema], description: String? = nil) -> JSONSchema { JSONSchema(.union(members), description: description) }

	public static func array(_ items: JSONSchema, minItems: Int? = nil, description: String? = nil) -> JSONSchema {
		JSONSchema(.array(items: items, minItems: minItems), description: description)
	}

	public static func object(_ properties: KeyValuePairs<String, JSONSchema>, additionalProperties: Bool? = nil, description: String? = nil) -> JSONSchema {
		object(properties: properties.map { Property($0.key, $0.value) }, additionalProperties: additionalProperties, description: description)
	}

	/// An object over an ordered property list (spreads: `{...base.properties}`).
	public static func object(properties: [Property], additionalProperties: Bool? = nil, description: String? = nil) -> JSONSchema {
		JSONSchema(.object(properties: properties, additionalProperties: additionalProperties), description: description)
	}

	/// `Type.Optional(schema)`.
	public func optional() -> JSONSchema {
		var s = self
		s.isOptional = true
		return s
	}

	/// An object schema's properties, in declaration order ([] otherwise).
	public var properties: [Property] {
		if case .object(let p, _) = kind { return p }
		return []
	}

	public func property(_ name: String) -> JSONSchema? { properties.first { $0.name == name }?.schema }

	/// The JSON Schema `type` keyword as emitted (a literal carries its
	/// constant's type; unions and enums carry none).
	public var jsonType: String? {
		switch kind {
		case .string: "string"
		case .boolean: "boolean"
		case .number: "number"
		case .integer: "integer"
		case .null: "null"
		case .literal(let v): v.jsTypeof
		case .array: "array"
		case .object: "object"
		case .enumeration, .union: nil
		}
	}
}

// MARK: - JSON Schema emission

extension JSONSchema {
	/// The JSON Schema object, keyed in typebox's order
	/// (`JSON.parse(JSON.stringify(schema))`).
	public var json: JSONValue {
		var o = JSONObject()
		switch kind {
		case .string, .boolean, .number, .integer, .null:
			if let minLength { o["minLength"] = .number(minLength) }
			if let minimum { o["minimum"] = .number(JSONNumber(minimum)) }
			o["type"] = .string(jsonType!)
		case .literal(let v):
			o["type"] = .string(v.jsTypeof)
			o["const"] = v
		case .enumeration(let values):
			o["enum"] = .array(values)
		case .array(let items, let minItems):
			o["type"] = "array"
			o["items"] = items.json
			if let minItems { o["minItems"] = .number(minItems) }
		case .object(let props, let additional):
			o["type"] = "object"
			let required = props.filter { !$0.schema.isOptional }.map { JSONValue.string($0.name) }
			if !required.isEmpty { o["required"] = .array(required) }
			o["properties"] = .object(JSONObject(pairs: props.map { ($0.name, $0.schema.json) }))
			if let additional { o["additionalProperties"] = .bool(additional) }
		case .union(let members):
			o["anyOf"] = .array(members.map(\.json))
		}
		if let description { o["description"] = .string(description) }
		return .object(o)
	}
}
