import Foundation

/// A small JSON Schema validator covering the keywords
/// `conformance/batch.schema.json` uses: type, enum, const, pattern,
/// minLength, maxLength, minItems, maxItems, items, required, properties,
/// $ref (local), allOf, anyOf, not, if/then.
struct SchemaValidator {
    let root: [String: Any]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "SchemaValidator", code: 1, userInfo: [NSLocalizedDescriptionKey: "schema is not an object"])
        }
        root = object
    }

    static let batch: SchemaValidator = try! SchemaValidator(url: RepoPaths.batchSchema)

    /// Errors for a raw request body (empty when valid).
    func validate(body: Data) -> [String] {
        guard let instance = try? JSONSerialization.jsonObject(with: body) else {
            return ["$: body is not JSON"]
        }
        return validate(instance)
    }

    func validate(_ instance: Any) -> [String] {
        return validate(instance, schema: root, path: "$")
    }

    private func resolve(_ schema: [String: Any]) -> [String: Any] {
        guard let ref = schema["$ref"] as? String, ref.hasPrefix("#/") else { return schema }
        var node: Any = root
        for part in ref.dropFirst(2).split(separator: "/") {
            guard let dict = node as? [String: Any], let next = dict[String(part)] else { return [:] }
            node = next
        }
        return resolve(node as? [String: Any] ?? [:])
    }

    private func validate(_ value: Any, schema raw: [String: Any], path: String) -> [String] {
        let schema = resolve(raw)
        var errors: [String] = []

        if let type = schema["type"] as? String, !matches(value, type: type) {
            return ["\(path): expected \(type)"]
        }
        if let options = schema["enum"] as? [Any], !options.contains(where: { equal($0, value) }) {
            errors.append("\(path): \(value) not in \(options)")
        }
        if let constant = schema["const"], !equal(constant, value) {
            errors.append("\(path): expected \(constant)")
        }
        if let string = value as? String {
            let length = string.unicodeScalars.count
            if let min = schema["minLength"] as? Int, length < min { errors.append("\(path): shorter than \(min)") }
            if let max = schema["maxLength"] as? Int, length > max { errors.append("\(path): longer than \(max)") }
            if let pattern = schema["pattern"] as? String {
                let regex = try? NSRegularExpression(pattern: pattern)
                let range = NSRange(string.startIndex..., in: string)
                if regex?.firstMatch(in: string, range: range) == nil {
                    errors.append("\(path): \"\(string)\" does not match \(pattern)")
                }
            }
        }
        if let array = value as? [Any], !isNumberOrBool(value) {
            if let min = schema["minItems"] as? Int, array.count < min { errors.append("\(path): fewer than \(min) items") }
            if let max = schema["maxItems"] as? Int, array.count > max { errors.append("\(path): more than \(max) items") }
            if let items = schema["items"] as? [String: Any] {
                for (index, item) in array.enumerated() {
                    errors += validate(item, schema: items, path: "\(path)[\(index)]")
                }
            }
        }
        if let object = value as? [String: Any] {
            for key in schema["required"] as? [String] ?? [] where object[key] == nil {
                errors.append("\(path): missing \(key)")
            }
            for (key, subschema) in schema["properties"] as? [String: Any] ?? [:] {
                if let child = object[key], let subschema = subschema as? [String: Any] {
                    errors += validate(child, schema: subschema, path: "\(path).\(key)")
                }
            }
        }
        for subschema in schema["allOf"] as? [[String: Any]] ?? [] {
            errors += validate(value, schema: subschema, path: path)
        }
        if let anyOf = schema["anyOf"] as? [[String: Any]],
           !anyOf.contains(where: { validate(value, schema: $0, path: path).isEmpty }) {
            errors.append("\(path): matches none of anyOf")
        }
        if let not = schema["not"] as? [String: Any], validate(value, schema: not, path: path).isEmpty {
            errors.append("\(path): matches a schema it must not match")
        }
        if let condition = schema["if"] as? [String: Any], validate(value, schema: condition, path: path).isEmpty,
           let then = schema["then"] as? [String: Any] {
            errors += validate(value, schema: then, path: path)
        }
        return errors
    }

    private func isNumberOrBool(_ value: Any) -> Bool {
        return value is NSNumber
    }

    private func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any] && !(value is NSNumber) && !(value is String)
        case "string": return value is String
        case "boolean": return isBool(value)
        case "number": return value is NSNumber && !isBool(value)
        case "integer":
            guard let number = value as? NSNumber, !isBool(value) else { return false }
            return number.doubleValue == number.doubleValue.rounded()
        case "null": return value is NSNull
        default: return true
        }
    }

    private func equal(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? String, let b = b as? String { return a == b }
        if a is String || b is String { return false }
        if let a = a as? NSObject, let b = b as? NSObject { return a.isEqual(b) }
        return false
    }
}
