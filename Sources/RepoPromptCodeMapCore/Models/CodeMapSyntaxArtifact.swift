import Foundation

// MARK: - Source-derived symbol values

package struct InterfaceInfo: Codable, Equatable, Sendable {
    package let name: String
    package var properties: [PropertyInfo]
    package var methods: [FunctionInfo]

    package init(name: String, properties: [PropertyInfo] = [], methods: [FunctionInfo] = []) {
        self.name = name
        self.properties = properties
        self.methods = methods
    }
}

package struct TypeAliasInfo: Codable, Equatable, Sendable {
    package let name: String
    package let definitionLine: String

    package init(name: String, definitionLine: String) {
        self.name = name
        self.definitionLine = definitionLine
    }
}

package struct ClassInfo: Codable, Equatable, Sendable {
    package let name: String
    package var methods: [FunctionInfo]
    package var properties: [PropertyInfo]

    package init(name: String, methods: [FunctionInfo], properties: [PropertyInfo]) {
        self.name = name
        self.methods = methods
        self.properties = properties
    }
}

package struct FunctionInfo: Codable, Equatable, Sendable {
    package let name: String
    package var parameters: [ParameterInfo]
    package var returnType: String?
    package let definitionLine: String
    package let lineNumber: Int?

    package init(
        name: String,
        parameters: [ParameterInfo],
        returnType: String?,
        definitionLine: String,
        lineNumber: Int?
    ) {
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.definitionLine = definitionLine
        self.lineNumber = lineNumber
    }
}

package struct ParameterInfo: Codable, Equatable, Sendable {
    package let externalName: String?
    package let localName: String
    package var typeName: String?

    package init(externalName: String?, localName: String, typeName: String?) {
        self.externalName = externalName
        self.localName = localName
        self.typeName = typeName
    }
}

package struct PropertyInfo: Codable, Equatable, Sendable {
    package let name: String
    package let typeName: String?

    package init(name: String, typeName: String?) {
        self.name = name
        self.typeName = typeName
    }
}

package struct VariableInfo: Codable, Equatable, Sendable {
    package let name: String
    package let typeName: String?
    package let definitionLine: String

    package init(name: String, typeName: String?, definitionLine: String) {
        self.name = name
        self.typeName = typeName
        self.definitionLine = definitionLine
    }
}

package struct EnumInfo: Codable, Equatable, Sendable {
    package let name: String
    package var cases: [String]

    package init(name: String, cases: [String]) {
        self.name = name
        self.cases = cases
    }
}

// MARK: - Shared path-free formatting

package struct CodeMapAPIContentSummary: Sendable {
    package let apiDescription: String
    package let definedTypeNames: Set<String>
}

package enum CodeMapAPIContentFormatter {
    package static func summarize(
        classes: [ClassInfo],
        interfaces: [InterfaceInfo],
        aliases: [TypeAliasInfo],
        literalUnions: [String],
        functions: [FunctionInfo],
        enums: [EnumInfo],
        globalVars: [VariableInfo],
        exports: [String],
        macros: [String]
    ) -> CodeMapAPIContentSummary {
        var lines = ["---"]

        func formatFunctionLine(_ function: FunctionInfo) -> String {
            if let line = function.lineNumber {
                return "L\(line): \(function.definitionLine)"
            }
            return function.definitionLine
        }

        func formatPropertyLine(_ name: String, typeName: String?) -> String {
            guard let typeName, !typeName.isEmpty else { return name }
            if name.contains(":") { return name }
            return "\(name): \(typeName)"
        }

        if !classes.isEmpty {
            lines.append("Classes:")
            for classInfo in classes {
                lines.append("  - \(classInfo.name)")
                if !classInfo.methods.isEmpty {
                    lines.append("    Methods:")
                    for method in classInfo.methods {
                        lines.append("      - \(formatFunctionLine(method))")
                    }
                }
                if !classInfo.properties.isEmpty {
                    lines.append("    Properties:")
                    for property in classInfo.properties {
                        lines.append("      - \(formatPropertyLine(property.name, typeName: property.typeName))")
                    }
                }
            }
        }
        if !interfaces.isEmpty {
            lines.append("")
            lines.append("Interfaces:")
            for interface in interfaces {
                lines.append("  - \(interface.name)")
                if !interface.methods.isEmpty {
                    lines.append("    Methods:")
                    for method in interface.methods {
                        lines.append("      - \(formatFunctionLine(method))")
                    }
                }
                if !interface.properties.isEmpty {
                    lines.append("    Properties:")
                    for property in interface.properties {
                        lines.append("      - \(formatPropertyLine(property.name, typeName: property.typeName))")
                    }
                }
            }
        }
        if !aliases.isEmpty {
            lines.append("")
            lines.append("Type-aliases:")
            for alias in aliases {
                lines.append("  - \(alias.name)")
            }
        }
        if !literalUnions.isEmpty {
            lines.append("")
            lines.append("Literal-union aliases:")
            for literalUnion in literalUnions {
                lines.append("  - \(literalUnion)")
            }
        }
        if !functions.isEmpty {
            lines.append("")
            lines.append("Functions:")
            for function in functions {
                lines.append("  - \(formatFunctionLine(function))")
            }
        }
        if !enums.isEmpty {
            lines.append("")
            lines.append("Enums:")
            for enumInfo in enums {
                lines.append("  - \(enumInfo.name)")
            }
        }
        if !globalVars.isEmpty {
            lines.append("")
            lines.append("Global vars:")
            for variable in globalVars {
                lines.append("  - \(formatPropertyLine(variable.name, typeName: variable.typeName))")
            }
        }
        if !exports.isEmpty {
            lines.append("")
            lines.append("Exports:")
            for export in exports {
                lines.append("  - \(export)")
            }
        }
        if !macros.isEmpty {
            lines.append("")
            lines.append("Macros:")
            for macro in macros {
                lines.append("  - \(macro)")
            }
        }
        lines.append("---")

        let apiDescription = "\n" + lines.joined(separator: "\n") + "\n"
        let definedTypeNames = Set(classes.map(\.name))
            .union(interfaces.map(\.name))
            .union(aliases.map(\.name))
            .union(enums.map(\.name))
        return CodeMapAPIContentSummary(
            apiDescription: apiDescription,
            definedTypeNames: definedTypeNames
        )
    }
}

// MARK: - Immutable path-free artifact

package struct CodeMapSyntaxArtifact: Codable, Equatable, Sendable {
    package let imports: [String]
    package let exports: [String]
    package let classes: [ClassInfo]
    package let interfaces: [InterfaceInfo]
    package let aliases: [TypeAliasInfo]
    package let literalUnions: [String]
    package let functions: [FunctionInfo]
    package let enums: [EnumInfo]
    package let globalVars: [VariableInfo]
    package let macros: [String]
    package let referencedTypes: [String]

    package let apiDescription: String
    package let definedTypeNames: Set<String>

    private enum CodingKeys: String, CodingKey {
        case imports, exports, classes, interfaces, aliases, literalUnions,
             functions, enums, globalVars, macros, referencedTypes
    }

    package init(
        imports: [String],
        exports: [String] = [],
        classes: [ClassInfo],
        interfaces: [InterfaceInfo] = [],
        aliases: [TypeAliasInfo] = [],
        literalUnions: [String] = [],
        functions: [FunctionInfo],
        enums: [EnumInfo],
        globalVars: [VariableInfo],
        macros: [String],
        referencedTypes: [String]
    ) {
        self.imports = imports
        self.exports = exports
        self.classes = classes
        self.interfaces = interfaces
        self.aliases = aliases
        self.literalUnions = literalUnions
        self.functions = functions
        self.enums = enums
        self.globalVars = globalVars
        self.macros = macros
        self.referencedTypes = referencedTypes

        let summary = CodeMapAPIContentFormatter.summarize(
            classes: classes,
            interfaces: interfaces,
            aliases: aliases,
            literalUnions: literalUnions,
            functions: functions,
            enums: enums,
            globalVars: globalVars,
            exports: exports,
            macros: macros
        )
        apiDescription = summary.apiDescription
        definedTypeNames = summary.definedTypeNames
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            imports: container.decode([String].self, forKey: .imports),
            exports: container.decode([String].self, forKey: .exports),
            classes: container.decode([ClassInfo].self, forKey: .classes),
            interfaces: container.decode([InterfaceInfo].self, forKey: .interfaces),
            aliases: container.decode([TypeAliasInfo].self, forKey: .aliases),
            literalUnions: container.decode([String].self, forKey: .literalUnions),
            functions: container.decode([FunctionInfo].self, forKey: .functions),
            enums: container.decode([EnumInfo].self, forKey: .enums),
            globalVars: container.decode([VariableInfo].self, forKey: .globalVars),
            macros: container.decode([String].self, forKey: .macros),
            referencedTypes: container.decode([String].self, forKey: .referencedTypes)
        )
    }
}

package enum CodeMapSyntaxOversizeReason: Codable, Equatable, Sendable {
    case utf8Bytes(actual: Int, limit: Int)
    case utf16Units(actual: Int, limit: Int)
    case lines(actual: Int, limit: Int)

    private enum CodingKeys: String, CodingKey { case kind, actual, limit }
    private enum Kind: String, Codable { case utf8Bytes, utf16Units, lines }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let actual = try container.decode(Int.self, forKey: .actual)
        let limit = try container.decode(Int.self, forKey: .limit)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .utf8Bytes: self = .utf8Bytes(actual: actual, limit: limit)
        case .utf16Units: self = .utf16Units(actual: actual, limit: limit)
        case .lines: self = .lines(actual: actual, limit: limit)
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .utf8Bytes(actual, limit):
            try container.encode(Kind.utf8Bytes, forKey: .kind)
            try container.encode(actual, forKey: .actual)
            try container.encode(limit, forKey: .limit)
        case let .utf16Units(actual, limit):
            try container.encode(Kind.utf16Units, forKey: .kind)
            try container.encode(actual, forKey: .actual)
            try container.encode(limit, forKey: .limit)
        case let .lines(actual, limit):
            try container.encode(Kind.lines, forKey: .kind)
            try container.encode(actual, forKey: .actual)
            try container.encode(limit, forKey: .limit)
        }
    }
}

package enum CodeMapSyntaxParseFailure: String, Codable, Equatable, Sendable {
    case parserReturnedNilTree
    case parserReturnedNilRoot
}

package enum CodeMapSyntaxArtifactOutcome: Codable, Equatable, Sendable {
    case ready(CodeMapSyntaxArtifact)
    case readyNoSymbols
    case oversize(CodeMapSyntaxOversizeReason)
    case decodeFailed(CodeMapSourceDecodeFailure)
    case parseFailed(CodeMapSyntaxParseFailure)

    private enum CodingKeys: String, CodingKey { case kind, artifact, reason, failure }
    private enum Kind: String, Codable { case ready, readyNoSymbols, oversize, decodeFailed, parseFailed }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .ready:
            self = try .ready(container.decode(CodeMapSyntaxArtifact.self, forKey: .artifact))
        case .readyNoSymbols:
            self = .readyNoSymbols
        case .oversize:
            self = try .oversize(container.decode(CodeMapSyntaxOversizeReason.self, forKey: .reason))
        case .decodeFailed:
            self = try .decodeFailed(container.decode(CodeMapSourceDecodeFailure.self, forKey: .failure))
        case .parseFailed:
            self = try .parseFailed(container.decode(CodeMapSyntaxParseFailure.self, forKey: .failure))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ready(artifact):
            try container.encode(Kind.ready, forKey: .kind)
            try container.encode(artifact, forKey: .artifact)
        case .readyNoSymbols:
            try container.encode(Kind.readyNoSymbols, forKey: .kind)
        case let .oversize(reason):
            try container.encode(Kind.oversize, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case let .decodeFailed(failure):
            try container.encode(Kind.decodeFailed, forKey: .kind)
            try container.encode(failure, forKey: .failure)
        case let .parseFailed(failure):
            try container.encode(Kind.parseFailed, forKey: .kind)
            try container.encode(failure, forKey: .failure)
        }
    }
}
