import Foundation

/// Loose JSON object, the Swift twin of the Kotlin side's `JsonObject` reads: the gateway's
/// payloads are tolerant-by-design (`ignoreUnknownKeys`), so parsers pick fields, never decode
/// whole schemas.
public typealias JSONObject = [String: Any]

public enum JSON {
    public static func object(_ text: String) throws -> JSONObject {
        try object(Data(text.utf8))
    }

    public static func object(_ data: Data) throws -> JSONObject {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw ApiError(code: 0, message: "not a JSON object")
        }
        return obj
    }

    /// Request bodies: JSONSerialization does the escaping the Kotlin `esc()` did by hand.
    public static func body(_ obj: JSONObject) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }
}

extension Dictionary where Key == String, Value == Any {
    /// Primitive content as text, blank → nil (Kotlin `JsonObject.str`). Numbers stringify.
    public func str(_ key: String) -> String? {
        guard let v = self[key] else { return nil }
        let s: String?
        if let t = v as? String { s = t }
        else if JSON.isBool(v) { s = (v as! NSNumber).boolValue ? "true" : "false" }
        else if let n = v as? NSNumber { s = n.stringValue }
        else { s = nil }
        guard let out = s, !out.isEmpty else { return nil }
        return out
    }

    /// true/false as BOOLEANs only — a `"true"` string is a value, not a flag.
    public func bool(_ key: String) -> Bool? {
        guard let v = self[key], JSON.isBool(v) else { return nil }
        return (v as! NSNumber).boolValue
    }

    public func double(_ key: String) -> Double? {
        if let v = self[key], !JSON.isBool(v), let n = v as? NSNumber { return n.doubleValue }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }

    public func int(_ key: String) -> Int? {
        double(key).map { Int($0) }
    }

    public func object(_ key: String) -> JSONObject? { self[key] as? JSONObject }

    public func array(_ key: String) -> [Any]? { self[key] as? [Any] }

    /// Approval choices: `[{id}]` or `["approve", …]`; nothing usable → approve/deny.
    public func choiceNames() -> [String] {
        let names = (array("choices") ?? []).compactMap { el -> String? in
            if let o = el as? JSONObject { return o.str("id") }
            if let s = el as? String, !s.isEmpty { return s }
            return nil
        }
        return names.isEmpty ? ["approve", "deny"] : names
    }
}

public struct ApiError: Error, LocalizedError, Equatable {
    public let code: Int
    public let message: String
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
    public var errorDescription: String? { message }
}
