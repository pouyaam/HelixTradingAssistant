import Foundation

/// A dynamic JSON value.
///
/// MCP payloads are open-ended — tool arguments arrive as arbitrary
/// objects and tool results are whatever shape the tool wants — so the
/// wire layer can't be expressed as fixed `Codable` structs. This is the
/// escape hatch: `Codable` in both directions, with typed accessors so
/// tool implementations don't hand-roll casts.
indirect enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                              { self = .null; return }
        if let v = try? c.decode(Bool.self)           { self = .bool(v); return }
        if let v = try? c.decode(Double.self)         { self = .number(v); return }
        if let v = try? c.decode(String.self)         { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self)    { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let v):   try c.encode(v)
        case .number(let v):
            // Whole numbers encode as integers so `"bars": 500` doesn't
            // come back as `500.0` — clients that validate arguments
            // against an integer schema reject the float form.
            if v.rounded() == v, abs(v) < 9.2e18 { try c.encode(Int(v)) }
            else                                 { try c.encode(v) }
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // ── Typed accessors ────────────────────────────────────────────

    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var doubleValue: Double? {
        switch self {
        case .number(let v): return v
        // Clients that stringify numbers ("bars": "500") are common
        // enough — and harmless enough — to accept.
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var intValue: Int? { doubleValue.map { Int($0) } }
    var boolValue: Bool? {
        switch self {
        case .bool(let v):   return v
        case .string(let s): return s == "true" ? true : (s == "false" ? false : nil)
        default: return nil
        }
    }
    var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }

    subscript(key: String) -> JSONValue? { objectValue?[key] }

    // ── Construction from Encodable ────────────────────────────────

    /// Round-trip any `Encodable` into a `JSONValue`. Used by tools that
    /// already have a `Codable` result type (the SMC evidence pack) and
    /// shouldn't have to restate it as a dictionary literal.
    static func from<T: Encodable>(_ value: T, encoder: JSONEncoder = MCP.encoder) throws -> JSONValue {
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func object(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var dict: [String: JSONValue] = [:]
        for (k, v) in pairs { dict[k] = v }
        return .object(dict)
    }
}

// Sugar so tool result builders read like JSON literals.
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String)  { self = .string(value) }
    init(floatLiteral value: Double)   { self = .number(value) }
    init(integerLiteral value: Int)    { self = .number(Double(value)) }
    init(booleanLiteral value: Bool)   { self = .bool(value) }
}

// MARK: - JSON-RPC 2.0

/// An incoming JSON-RPC request. `id` is absent for notifications, which
/// must not be answered — the server distinguishes them by that alone.
struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: JSONValue?
    let method: String
    let params: JSONValue?
}

struct JSONRPCError: Error, Equatable {
    let code: Int
    let message: String
    var data: JSONValue? = nil

    // Standard JSON-RPC codes.
    static func parseError(_ m: String = "Parse error") -> JSONRPCError { .init(code: -32700, message: m) }
    static func invalidRequest(_ m: String = "Invalid request") -> JSONRPCError { .init(code: -32600, message: m) }
    static func methodNotFound(_ m: String) -> JSONRPCError { .init(code: -32601, message: "Method not found: \(m)") }
    static func invalidParams(_ m: String) -> JSONRPCError { .init(code: -32602, message: m) }
    static func internalError(_ m: String) -> JSONRPCError { .init(code: -32603, message: m) }
}

/// A JSON-RPC response, built directly as a `JSONValue` tree because the
/// `result` payload is tool-defined.
enum JSONRPCResponse {
    case success(id: JSONValue, result: JSONValue)
    case failure(id: JSONValue?, error: JSONRPCError)

    var json: JSONValue {
        switch self {
        case .success(let id, let result):
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        case .failure(let id, let error):
            var errObj: [String: JSONValue] = [
                "code": .number(Double(error.code)),
                "message": .string(error.message),
            ]
            if let d = error.data { errObj["data"] = d }
            return .object([
                "jsonrpc": .string("2.0"),
                "id": id ?? .null,
                "error": .object(errObj),
            ])
        }
    }
}

// MARK: - MCP shared constants

enum MCP {
    /// Protocol revision this server implements. Reported verbatim in the
    /// `initialize` result; clients that speak a newer revision negotiate
    /// down to it.
    static let protocolVersion = "2025-06-18"
    static let serverName = "helix-trading"

    static var serverVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Shared encoder. ISO-8601 dates because every timestamp crossing
    /// this boundary is a bar time, and clients (and the models reading
    /// them) parse ISO far more reliably than epoch seconds.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// The matching decoder. Anything encoded with `encoder` must be read
    /// back through this one — the default strategy expects epoch numbers
    /// and fails on the ISO strings above.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// One tool the server exposes.
struct MCPTool {
    let name: String
    let title: String
    let description: String
    /// JSON Schema for the tool's arguments.
    let inputSchema: JSONValue
    /// Runs the tool. Throws `JSONRPCError` for argument problems.
    /// Called off the main thread on the connection's queue.
    let run: ([String: JSONValue]) throws -> JSONValue

    var listing: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
        ])
    }
}

// MARK: - Schema helpers

/// Small builders for JSON Schema fragments. Tool definitions are the
/// server's documentation — an agent picks a tool purely from this text —
/// so keeping the construction terse keeps the descriptions readable.
enum MCPSchema {
    static func object(
        properties: KeyValuePairs<String, JSONValue>,
        required: [String] = []
    ) -> JSONValue {
        var props: [String: JSONValue] = [:]
        for (k, v) in properties { props[k] = v }
        return .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }

    static func string(_ description: String, enum values: [String]? = nil, default def: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let values { o["enum"] = .array(values.map { .string($0) }) }
        if let def { o["default"] = .string(def) }
        return .object(o)
    }

    static func integer(_ description: String, min: Int? = nil, max: Int? = nil, default def: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("integer"), "description": .string(description)]
        if let min { o["minimum"] = .number(Double(min)) }
        if let max { o["maximum"] = .number(Double(max)) }
        if let def { o["default"] = .number(Double(def)) }
        return .object(o)
    }

    static func number(_ description: String, min: Double? = nil, max: Double? = nil, default def: Double? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("number"), "description": .string(description)]
        if let min { o["minimum"] = .number(min) }
        if let max { o["maximum"] = .number(max) }
        if let def { o["default"] = .number(def) }
        return .object(o)
    }

    static func boolean(_ description: String, default def: Bool? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("boolean"), "description": .string(description)]
        if let def { o["default"] = .bool(def) }
        return .object(o)
    }
}
