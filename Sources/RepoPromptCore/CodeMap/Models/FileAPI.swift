import Foundation

// MARK: - Supporting Types

package struct InterfaceInfo: Codable {
    package let name: String
    package var properties: [PropertyInfo]
    package var methods: [FunctionInfo]

    package init(name: String, properties: [PropertyInfo] = [], methods: [FunctionInfo] = []) {
        self.name = name
        self.properties = properties
        self.methods = methods
    }
}

package struct TypeAliasInfo: Codable {
    package let name: String
    package let definitionLine: String

    package init(name: String, definitionLine: String) {
        self.name = name
        self.definitionLine = definitionLine
    }
}

package struct ClassInfo: Codable {
    package let name: String
    package var methods: [FunctionInfo]
    package var properties: [PropertyInfo]

    package init(name: String, methods: [FunctionInfo], properties: [PropertyInfo]) {
        self.name = name
        self.methods = methods
        self.properties = properties
    }
}

package struct FunctionInfo: Codable {
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

package struct ParameterInfo: Codable {
    package let externalName: String?
    package let localName: String
    package var typeName: String?

    package init(externalName: String?, localName: String, typeName: String?) {
        self.externalName = externalName
        self.localName = localName
        self.typeName = typeName
    }
}

package struct PropertyInfo: Codable {
    package let name: String
    package let typeName: String?

    package init(name: String, typeName: String?) {
        self.name = name
        self.typeName = typeName
    }
}

package struct VariableInfo: Codable {
    package let name: String
    package let typeName: String?
    package let definitionLine: String

    package init(name: String, typeName: String?, definitionLine: String) {
        self.name = name
        self.typeName = typeName
        self.definitionLine = definitionLine
    }
}

package struct EnumInfo: Codable {
    package let name: String
    package var cases: [String]

    package init(name: String, cases: [String]) {
        self.name = name
        self.cases = cases
    }
}

/// Represents a structured "API surface" for a file.
package struct FileAPI: Codable {
    package let filePath: String
    package var imports: [String]
    package var exports: [String]
    package var classes: [ClassInfo]
    package var interfaces: [InterfaceInfo]
    package var aliases: [TypeAliasInfo]
    package var literalUnions: [String]
    package var functions: [FunctionInfo]
    package var enums: [EnumInfo]
    package var globalVars: [VariableInfo]
    package var macros: [String]
    package let referencedTypes: [String]

    package let apiDescription: String
    package let definedTypeNames: Set<String>
    package let pathAndImportsDescription: String
    package let apiTokenCount: Int

    package enum CodingKeys: String, CodingKey {
        case filePath, imports, exports, classes, interfaces, aliases,
             literalUnions, functions, enums, globalVars, macros, referencedTypes
    }

    package init(
        filePath: String,
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
        self.filePath = filePath
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
            for union in literalUnions {
                lines.append("  - \(union)")
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

        apiDescription = "\n" + lines.joined(separator: "\n") + "\n"
        definedTypeNames = Set(classes.map(\.name))
            .union(interfaces.map(\.name))
            .union(aliases.map(\.name))
            .union(enums.map(\.name))
        pathAndImportsDescription = Self.pathAndImportsBlock(displayPath: filePath, imports: imports)
        apiTokenCount = TokenCalculationService.estimateTokens(for: apiDescription)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filePath, forKey: .filePath)
        try container.encode(imports, forKey: .imports)
        try container.encode(exports, forKey: .exports)
        try container.encode(classes, forKey: .classes)
        try container.encode(interfaces, forKey: .interfaces)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(literalUnions, forKey: .literalUnions)
        try container.encode(functions, forKey: .functions)
        try container.encode(enums, forKey: .enums)
        try container.encode(globalVars, forKey: .globalVars)
        try container.encode(macros, forKey: .macros)
        try container.encode(referencedTypes, forKey: .referencedTypes)
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            filePath: container.decode(String.self, forKey: .filePath),
            imports: container.decode([String].self, forKey: .imports),
            exports: container.decodeIfPresent([String].self, forKey: .exports) ?? [],
            classes: container.decode([ClassInfo].self, forKey: .classes),
            interfaces: container.decodeIfPresent([InterfaceInfo].self, forKey: .interfaces) ?? [],
            aliases: container.decodeIfPresent([TypeAliasInfo].self, forKey: .aliases) ?? [],
            literalUnions: container.decodeIfPresent([String].self, forKey: .literalUnions) ?? [],
            functions: container.decode([FunctionInfo].self, forKey: .functions),
            enums: container.decode([EnumInfo].self, forKey: .enums),
            globalVars: container.decode([VariableInfo].self, forKey: .globalVars),
            macros: container.decode([String].self, forKey: .macros),
            referencedTypes: container.decode([String].self, forKey: .referencedTypes)
        )
    }

    package func getFullAPIDescription() -> String {
        getFullAPIDescription(displayPath: filePath)
    }

    package func getFullAPIDescription(displayPath: String) -> String {
        let pathAndImports = Self.pathAndImportsBlock(displayPath: displayPath, imports: imports)
        return [pathAndImports, apiDescription].joined()
    }

    package func estimatedFullAPIDescriptionTokens(displayPath: String) -> Int {
        TokenCalculationService.estimateTokens(for: Self.pathAndImportsBlock(displayPath: displayPath, imports: imports)) + apiTokenCount
    }

    package func printAPI() {
        print(apiDescription)
    }

    private static func pathAndImportsBlock(displayPath: String, imports: [String]) -> String {
        (["File: \(displayPath)", "Imports:"] + imports.map { "  - \($0)" }).joined(separator: "\n")
    }
}
