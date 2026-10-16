import Foundation
import MCP

// MARK: - Schema Documentation Models

/// Where allowed values apply: to the value itself or to array items
enum AllowedValuesScope {
    case value // enum on the value itself
    case arrayItems // enum on items within an array
}

/// Represents a variant of a parameter (for oneOf/anyOf)
struct ToolParameterVariantDoc {
    let typeDescription: String
    let description: String?
    let allowedValues: [String]?
    let defaultValue: String?
    let children: [ToolParameterDoc]
}

/// Represents a parameter from a tool's JSON schema.
struct ToolParameterDoc {
    let name: String
    let typeDescription: String
    let required: Bool
    let description: String?
    let allowedValues: [String]?
    let allowedValuesScope: AllowedValuesScope
    let defaultValue: String?
    let children: [ToolParameterDoc]
    /// For parameters with oneOf/anyOf, the individual type variants
    let variants: [ToolParameterVariantDoc]

    init(
        name: String,
        typeDescription: String,
        required: Bool,
        description: String?,
        allowedValues: [String]?,
        allowedValuesScope: AllowedValuesScope = .value,
        defaultValue: String?,
        children: [ToolParameterDoc],
        variants: [ToolParameterVariantDoc] = []
    ) {
        self.name = name
        self.typeDescription = typeDescription
        self.required = required
        self.description = description
        self.allowedValues = allowedValues
        self.allowedValuesScope = allowedValuesScope
        self.defaultValue = defaultValue
        self.children = children
        self.variants = variants
    }
}

/// Represents a variant/shape at the root level (for tools with mutually-exclusive input shapes)
struct ToolSchemaVariantDoc {
    let title: String?
    let description: String?
    let parameters: [ToolParameterDoc]
}

/// Represents the documentation for a tool's entire schema.
struct ToolSchemaDoc {
    let title: String?
    let description: String?
    let parameters: [ToolParameterDoc]
    /// For tools with mutually-exclusive input shapes (oneOf at root)
    let variants: [ToolSchemaVariantDoc]

    init(title: String?, description: String?, parameters: [ToolParameterDoc], variants: [ToolSchemaVariantDoc] = []) {
        self.title = title
        self.description = description
        self.parameters = parameters
        self.variants = variants
    }
}

// MARK: - Schema Introspector

/// Extracts documentation from MCP JSON Schema values.
enum ToolSchemaIntrospector {
    /// Extracts a ToolSchemaDoc from an MCP Value representing a JSON Schema.
    static func extractDoc(from schema: Value?) -> ToolSchemaDoc {
        guard let schema else {
            return ToolSchemaDoc(title: nil, description: nil, parameters: [])
        }

        guard case let .object(obj) = schema else {
            return ToolSchemaDoc(title: nil, description: nil, parameters: [])
        }

        let title = extractString(obj["title"])
        let description = extractString(obj["description"])

        // Check for root-level oneOf/anyOf (mutually-exclusive input shapes)
        let variants = extractRootVariants(obj)
        if !variants.isEmpty {
            return ToolSchemaDoc(title: title, description: description, parameters: [], variants: variants)
        }

        let parameters = extractParameters(fromObjectSchema: obj)
        return ToolSchemaDoc(title: title, description: description, parameters: parameters)
    }

    /// Extracts root-level variants from oneOf/anyOf
    private static func extractRootVariants(_ obj: [String: Value]) -> [ToolSchemaVariantDoc] {
        // Check for oneOf
        if let oneOf = obj["oneOf"], case let .array(options) = oneOf {
            return options.compactMap { extractVariant(from: $0) }
        }
        // Check for anyOf
        if let anyOf = obj["anyOf"], case let .array(options) = anyOf {
            return options.compactMap { extractVariant(from: $0) }
        }
        return []
    }

    /// Extracts a single variant from a schema option
    private static func extractVariant(from value: Value?) -> ToolSchemaVariantDoc? {
        guard case let .object(obj) = value else { return nil }
        let title = extractString(obj["title"])
        let description = extractString(obj["description"])
        let parameters = extractParameters(fromObjectSchema: obj)
        return ToolSchemaVariantDoc(title: title, description: description, parameters: parameters)
    }

    /// Extracts parameters from an object schema's properties
    private static func extractParameters(fromObjectSchema obj: [String: Value]) -> [ToolParameterDoc] {
        let requiredNames = extractStringArray(obj["required"])
        let properties = extractObject(obj["properties"])

        var parameters: [ToolParameterDoc] = []
        for (name, propValue) in properties.sorted(by: { $0.key < $1.key }) {
            let param = extractParameter(name: name, value: propValue, required: requiredNames.contains(name))
            parameters.append(param)
        }

        // Sort with required parameters first, then alphabetically
        parameters.sort { a, b in
            if a.required != b.required { return a.required }
            return a.name < b.name
        }

        return parameters
    }

    private static func extractParameter(name: String, value: Value?, required: Bool) -> ToolParameterDoc {
        guard case let .object(obj) = value else {
            return ToolParameterDoc(
                name: name,
                typeDescription: "unknown",
                required: required,
                description: nil,
                allowedValues: nil,
                allowedValuesScope: .value,
                defaultValue: nil,
                children: [],
                variants: []
            )
        }

        let typeDesc = extractTypeDescription(obj)
        let description = extractString(obj["description"])
        var allowedValues = extractEnumValues(obj["enum"])
        var allowedValuesScope: AllowedValuesScope = .value
        let defaultValue = extractDefaultValue(obj["default"])
        let children = extractChildParameters(obj)

        // Check for array item enums
        if allowedValues == nil,
           let typeValue = obj["type"], case let .string(t) = typeValue, t == "array",
           let items = obj["items"], case let .object(itemObj) = items
        {
            if let itemEnums = extractEnumValues(itemObj["enum"]) {
                allowedValues = itemEnums
                allowedValuesScope = .arrayItems
            }
        }

        // Extract parameter-level variants (oneOf/anyOf)
        let variants = extractParameterVariants(obj)

        return ToolParameterDoc(
            name: name,
            typeDescription: typeDesc,
            required: required,
            description: description,
            allowedValues: allowedValues,
            allowedValuesScope: allowedValuesScope,
            defaultValue: defaultValue,
            children: children,
            variants: variants
        )
    }

    /// Extracts variants for a parameter with oneOf/anyOf
    private static func extractParameterVariants(_ obj: [String: Value]) -> [ToolParameterVariantDoc] {
        var options: [Value] = []
        if let oneOf = obj["oneOf"], case let .array(arr) = oneOf {
            options = arr
        } else if let anyOf = obj["anyOf"], case let .array(arr) = anyOf {
            options = arr
        }

        guard !options.isEmpty else { return [] }

        return options.compactMap { opt -> ToolParameterVariantDoc? in
            guard case let .object(optObj) = opt else { return nil }
            let typeDesc = extractTypeDescription(optObj)
            let description = extractString(optObj["description"])
            let allowedValues = extractEnumValues(optObj["enum"])
            let defaultValue = extractDefaultValue(optObj["default"])
            let children = extractChildParameters(optObj)
            return ToolParameterVariantDoc(
                typeDescription: typeDesc,
                description: description,
                allowedValues: allowedValues,
                defaultValue: defaultValue,
                children: children
            )
        }
    }

    private static func extractTypeDescription(_ obj: [String: Value]) -> String {
        // Handle type field
        if let typeValue = obj["type"] {
            switch typeValue {
            case let .string(t):
                return formatType(t, obj)
            case let .array(types):
                let typeStrings = types.compactMap { extractString($0) }
                return typeStrings.joined(separator: " | ")
            default:
                break
            }
        }

        // Handle oneOf/anyOf
        if let oneOf = obj["oneOf"], case let .array(options) = oneOf {
            let types = options.compactMap { extractTypeFromValue($0) }
            return "oneOf(" + types.joined(separator: ", ") + ")"
        }

        if let anyOf = obj["anyOf"], case let .array(options) = anyOf {
            let types = options.compactMap { extractTypeFromValue($0) }
            return "anyOf(" + types.joined(separator: ", ") + ")"
        }

        return "any"
    }

    private static func formatType(_ type: String, _ obj: [String: Value]) -> String {
        switch type {
        case "array":
            if let items = obj["items"], case let .object(itemObj) = items {
                let itemType = extractTypeDescription(itemObj)
                return "array<\(itemType)>"
            }
            return "array"
        case "object":
            if let additionalProps = obj["additionalProperties"], case let .object(addObj) = additionalProps {
                let valueType = extractTypeDescription(addObj)
                return "object<string, \(valueType)>"
            }
            return "object"
        default:
            return type
        }
    }

    private static func extractTypeFromValue(_ value: Value?) -> String? {
        guard case let .object(obj) = value else { return nil }
        return extractTypeDescription(obj)
    }

    private static func extractChildParameters(_ obj: [String: Value]) -> [ToolParameterDoc] {
        // For objects, extract nested properties
        if let typeValue = obj["type"], case let .string(t) = typeValue, t == "object" {
            let requiredNames = extractStringArray(obj["required"])
            let properties = extractObject(obj["properties"])

            var children: [ToolParameterDoc] = []
            for (name, propValue) in properties.sorted(by: { $0.key < $1.key }) {
                let param = extractParameter(name: name, value: propValue, required: requiredNames.contains(name))
                children.append(param)
            }
            return children
        }

        // For arrays, extract item schema as a single child
        if let typeValue = obj["type"], case let .string(t) = typeValue, t == "array" {
            if let items = obj["items"], case let .object(itemObj) = items {
                // If items is an object type with properties, show those
                if let itemType = itemObj["type"], case let .string(it) = itemType, it == "object" {
                    let requiredNames = extractStringArray(itemObj["required"])
                    let properties = extractObject(itemObj["properties"])

                    var children: [ToolParameterDoc] = []
                    for (name, propValue) in properties.sorted(by: { $0.key < $1.key }) {
                        let param = extractParameter(name: name, value: propValue, required: requiredNames.contains(name))
                        children.append(param)
                    }
                    return children
                }
            }
        }

        return []
    }

    private static func extractEnumValues(_ value: Value?) -> [String]? {
        guard case let .array(arr) = value else { return nil }
        let values = arr.compactMap { v -> String? in
            switch v {
            case let .string(s): return s
            case let .int(i): return String(i)
            case let .double(d): return String(d)
            case let .bool(b): return String(b)
            default: return nil
            }
        }
        return values.isEmpty ? nil : values
    }

    private static func extractDefaultValue(_ value: Value?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .string(s): return "\"\(s)\""
        case let .int(i): return String(i)
        case let .double(d): return String(d)
        case let .bool(b): return String(b)
        case .null: return "null"
        default: return nil
        }
    }

    private static func extractString(_ value: Value?) -> String? {
        guard case let .string(s) = value else { return nil }
        return s
    }

    private static func extractStringArray(_ value: Value?) -> [String] {
        guard case let .array(arr) = value else { return [] }
        return arr.compactMap { extractString($0) }
    }

    private static func extractObject(_ value: Value?) -> [String: Value] {
        guard case let .object(obj) = value else { return [:] }
        return obj
    }
}

// MARK: - Schema Text Renderer

/// Renders tool schema documentation as human-readable text.
enum ToolSchemaTextRenderer {
    struct Options {
        var indent: String = "  "
        var maxDepth: Int = 4
        var maxEnumValues: Int = 10
        var showDefaults: Bool = true
        var useColor: Bool = false

        static let `default` = Options()
    }

    /// Renders a ToolSchemaDoc as formatted text.
    static func render(_ doc: ToolSchemaDoc, options: Options = .default) -> String {
        var lines: [String] = []

        // Handle root-level variants (mutually-exclusive input shapes)
        if !doc.variants.isEmpty {
            lines.append("Input Shapes (choose one):")
            lines.append("")
            for (index, variant) in doc.variants.enumerated() {
                let shapeNum = index + 1
                let title = variant.title ?? "Shape \(shapeNum)"
                lines.append("  [\(shapeNum)] \(title)")
                if let desc = variant.description {
                    lines.append("      " + desc)
                }
                if variant.parameters.isEmpty {
                    lines.append("      (no additional parameters)")
                } else {
                    for param in variant.parameters {
                        renderParameter(param, depth: 1, options: options, into: &lines)
                    }
                }
                lines.append("")
            }
            return lines.joined(separator: "\n")
        }

        if doc.parameters.isEmpty {
            lines.append("(no parameters)")
            return lines.joined(separator: "\n")
        }

        lines.append("Parameters:")
        lines.append("")

        for param in doc.parameters {
            renderParameter(param, depth: 0, options: options, into: &lines)
        }

        return lines.joined(separator: "\n")
    }

    private static func renderParameter(_ param: ToolParameterDoc, depth: Int, options: Options, into lines: inout [String]) {
        guard depth < options.maxDepth else { return }

        let baseIndent = String(repeating: options.indent, count: depth + 1)

        // Build the parameter line
        var paramLine = baseIndent
        paramLine += param.name
        paramLine += " ("
        paramLine += param.typeDescription
        if param.required {
            paramLine += ", required"
        }
        paramLine += ")"

        // Add allowed values inline if few
        if let values = param.allowedValues, values.count <= options.maxEnumValues {
            // Use "items:" prefix for array item enums to distinguish from value enums
            let prefix = param.allowedValuesScope == .arrayItems ? "items: " : ""
            paramLine += ": " + prefix + values.joined(separator: " | ")
        }

        // Add default if present
        if options.showDefaults, let defaultVal = param.defaultValue {
            paramLine += " [default: \(defaultVal)]"
        }

        lines.append(paramLine)

        // Add description on next line if present
        if let desc = param.description, !desc.isEmpty {
            let descIndent = baseIndent + options.indent
            // Wrap long descriptions
            let wrapped = wrapText(desc, width: 70, indent: descIndent)
            lines.append(wrapped)
        }

        // Render parameter-level variants (oneOf/anyOf options)
        if !param.variants.isEmpty {
            let variantIndent = baseIndent + options.indent
            lines.append(variantIndent + "Accepts one of:")
            for variant in param.variants {
                var variantLine = variantIndent + "  - " + variant.typeDescription
                if let values = variant.allowedValues, values.count <= options.maxEnumValues {
                    variantLine += ": " + values.joined(separator: " | ")
                }
                if let defaultVal = variant.defaultValue {
                    variantLine += " [default: \(defaultVal)]"
                }
                lines.append(variantLine)
                if let desc = variant.description {
                    lines.append(variantIndent + "    " + desc)
                }
                // Render variant children if it's an object
                for child in variant.children {
                    renderParameter(child, depth: depth + 2, options: options, into: &lines)
                }
            }
        }

        // Render children (nested properties)
        if !param.children.isEmpty {
            let childIndent = baseIndent + options.indent
            if param.typeDescription.hasPrefix("array<") {
                lines.append(childIndent + "Array items:")
            }
            for child in param.children {
                renderParameter(child, depth: depth + 1, options: options, into: &lines)
            }
        }

        lines.append("") // Blank line between parameters
    }

    private static func wrapText(_ text: String, width: Int, indent: String) -> String {
        let words = text.split(separator: " ")
        var lines: [String] = []
        var currentLine = indent

        for word in words {
            if currentLine.count + word.count + 1 > width, currentLine != indent {
                lines.append(currentLine)
                currentLine = indent + String(word)
            } else {
                if currentLine == indent {
                    currentLine += String(word)
                } else {
                    currentLine += " " + String(word)
                }
            }
        }

        if currentLine != indent {
            lines.append(currentLine)
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Convenience Extensions

extension MCP.Tool {
    /// Renders this tool's schema as human-readable documentation.
    func renderSchemaDoc(options: ToolSchemaTextRenderer.Options = .default) -> String {
        let doc = ToolSchemaIntrospector.extractDoc(from: inputSchema)
        return ToolSchemaTextRenderer.render(doc, options: options)
    }
}
