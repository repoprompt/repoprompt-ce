//
//  LanguageTypeExtractor.swift
//  RepoPrompt
//
//  Updated to handle additional edge cases such as:
//   - C++ trailing return (auto foo(...) -> ReturnType)
//   - Go multiple return types (func foo(...) (T1, T2))
//   - Swift generics right after function name (func name<T: Foo>...)
//   - TypeScript generics right after function name (function name<T extends Foo>...)
//   - TS "type Foo = ..." lines
//   - Python def ...: regex anchored to handle trailing colon.
//
//  The updated regex patterns and logic aim to fix test mismatches.
//  We also do a final .trimmingCharacters(in: .whitespacesAndNewlines)
//  on return types and param types to avoid trailing spaces.
//

import Foundation

/// A single struct holding all enhanced regex patterns and static helper methods
/// to extract variables and functions from lines of code for each language.
///
/// Each regex tries to capture relevant groups:
///   - For variables: "type" and "name"
///   - For functions: "returnType", "name", "paramList"
///
/// The main static struct that holds all regex patterns and
/// top-level “matchAny…” methods for variables & functions.
enum LanguageTypeExtractor {
    // SAFETY: These immutable standard-library Regex values are initialized once
    // and used only through nonmutating matching. Their type-erased outputs do
    // not currently carry Sendable conformance.
    // MARK: - Swift Patterns

    /// Now allows optional `<...>` generics right after function name.
    // MARK: - Swift Patterns

    /// Now allows optional `<...>` generics right after function name,
    /// plus newly added keywords such as weak, unowned, dynamic, distributed, isolated, etc.
    static let swiftFunctionRegex = CodeMapPCRE2Pattern(#"""
    (?xm)
    ^
    (?:[-*]\s*)?
    \s*
    (?:@[A-Za-z_]\w*(?:\([^)]*\))?\s*)*
    (?:
       (?:private\(set\)|public|private|internal|fileprivate|open|
       class|static|final|lazy|override|mutating|actor|async|
       nonisolated|isolated|required|convenience|indirect|inout|
       rethrows|throws|weak|unowned|dynamic|distributed)
       \s+
    )*
    func\s+
    ([A-Za-z_]\w*)
    (?:<[^>]+>)?    # <-- optional generics
    \s*
    \(
       ([^)]*)
    \)
    # Allow repeated groups of 'throws', 'rethrows', 'async' in any order
    (?:\s+(?:throws|rethrows|async))*
    # Optional return type
    (?:\s*->\s*(?:some\s+|any\s+)?([A-Za-z_\[\(][A-Za-z0-9_!\?\<\>\.\[\]\(\)\ \:\&\-]*))?
    \s*
    .*$
    """#)

    /// Updated with new Swift keywords for var/let.
    static let swiftVariableRegex = CodeMapPCRE2Pattern(#"""
    (?xm)
    ^
    (?:[-*]\s*)?
    \s*
    (?:@[A-Za-z_]\w*(?:\([^)]*\))?\s*)*
    (?:
       (?:private\(set\)|public|private|internal|fileprivate|open|class|static|final|lazy|override|mutating|actor|inout|
       required|convenience|indirect|weak|unowned|dynamic|distributed|isolated)
       \s+
    )*
    (?:var|let)\s+
    ([A-Za-z_]\w*)
    (?:\s*:\s*
     ([^=]+)
    )?
    .*$
    """#)

    // MARK: - C# Patterns

    nonisolated(unsafe) static let cSharpVariableRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^
    (?:public|private|protected|internal)?\s*
    (?:static\s+|const\s+|readonly\s+|volatile\s+|unsafe\s+)*
    ([A-Za-z_][A-Za-z0-9_\.\[\]]*
     (?:<[^>]+>)?
     \??)
    \s+(\**[A-Za-z_]\w*)
    """#)

    nonisolated(unsafe) static let cSharpFunctionRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^
    (?:public|private|protected|internal)?\s*
    (?:static\s+|sealed\s+|override\s+|abstract\s+|virtual\s+|unsafe\s+|async\s+)*
    ([A-Za-z_][A-Za-z0-9_\.<>\?\[\]&]+)
    \s+
    ([A-Za-z_]\w*)
    \s*\(
       ([^)]*)
    \)
    """#)

    // MARK: - Java

    nonisolated(unsafe) static let javaVariableRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^
    (?:public|private|protected)?\s*
    (?:static\s+|final\s+)*
    ([A-Za-z_][A-Za-z0-9_\.\[\]]*
     (?:<[^>]+>)?
    )
    \s+([A-Za-z_]\w*)
    """#)

    nonisolated(unsafe) static let javaFunctionRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^
    (?:public|private|protected)?\s*
    (?:static\s+|final\s+|synchronized\s+|abstract\s+)*
    ([A-Za-z_][A-Za-z0-9_\.\[\]]*(?:<[^>]+>)?)
    \s+
    ([A-Za-z_]\w*)
    \s*\(
       ([^)]*)
    \)
    """#)

    // MARK: - Dart

    nonisolated(unsafe) static let dartVariableRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^
    (?:
     (?:final|const)\s+
     ([A-Za-z_]\w*(?:<[^>]+>)?\??)
     \s+([A-Za-z_]\w*)
     |
     ([A-Za-z_]\w*(?:<[^>]+>)?\??)
     \s+([A-Za-z_]\w*)
    )
    """#)

    nonisolated(unsafe) static let dartFunctionRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^\s*
    (?:
    	([A-Za-z_][A-Za-z0-9_<>,\?\s]*?)   # group(1) => return type
    	\s+
    )?
    ([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?) # group(2) => function or named constructor
    \s*\(
    	([^)]*)?                       # group(3) => (partial) parameter list, may span lines
    .*$
    """#)

    nonisolated(unsafe) static let dartFactoryRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^\s*
    factory\s+
    ([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?)   # group(1) => factory name
    \s*\(
       ([^)]*)
    \)
    """#)

    nonisolated(unsafe) static let dartGetterSetterRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^\s*
    (?:([A-Za-z_][A-Za-z0-9_<>\?]+)\s+)?   # group(1) => optional return type
    (get|set)\s+
    ([A-Za-z_]\w*)                          # group(3) => name
    (?:\s*\(([^)]*)\))?                   # group(4) => optional params (setter)
    """#)

    // MARK: - C

    nonisolated(unsafe) static let cVariableRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^
    (?:extern|static|register)?\s*
    (?:const\s+|volatile\s+|unsigned\s+|signed\s+|long\s+|short\s+)*
    ([A-Za-z_][A-Za-z0-9_]*)
    (?:\s*\*+\s*)?
    \s+([A-Za-z_]\w*)
    """#)

    nonisolated(unsafe) static let cFunctionRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^
    (?:extern|static)?\s*
    (?:inline\s+|const\s+|volatile\s+|unsigned\s+|signed\s+|long\s+|short\s+)*
    ([A-Za-z_][A-Za-z0-9_\*]*)
    \s+
    ([A-Za-z_]\w*)
    \s*\(
       ([^)]*)
    \)
    """#)

    // MARK: - C++ (leading-return + trailing-return)

    nonisolated(unsafe) static let cppVariableRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^
    (?:extern|static|register|thread_local)?\s*
    (?:constexpr\s+|const\s+|volatile\s+|unsigned\s+|signed\s+|long\s+|short\s+|typename\s+)*
    ([A-Za-z_][A-Za-z0-9_:]*
     (?:<[^>]+>)?
    )
    (?:\s*[\*&]+)?
    \s+([A-Za-z_]\w*)
    """#)

    nonisolated(unsafe) static let cppFunctionRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^
    (?:template\s*<[^>]*>\s*)?
    (?:inline\s+|static\s+|virtual\s+|constexpr\s+|const\s+|unsigned\s+|signed\s+|long\s+|short\s+|typename\s+|friend\s+)*
    ([A-Za-z_][A-Za-z0-9_:<>\*\&]+)
    \s+
    ([A-Za-z_][A-Za-z0-9_:]*)
    \s*\(
       ([^)]*)
    \)
    """#)

    nonisolated(unsafe) static let cppConstructorRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^\s*
    (?:template\s*<[^>]*>\s*)?
    (?:inline\s+|explicit\s+|constexpr\s+|consteval\s+|constinit\s+|friend\s+)*
    ([A-Za-z_][A-Za-z0-9_:<>]*)
    \s*\(
       ([^)]*)
    \)
    """#)

    nonisolated(unsafe) static let cppTrailingReturnFunctionRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^
    (?:template\s*<[^>]*>\s*)?
    (?:inline\s+|static\s+|virtual\s+|constexpr\s+|const\s+|unsigned\s+|signed\s+|long\s+|short\s+|typename\s+|friend\s+)*
    auto
    \s+
    ([A-Za-z_][A-Za-z0-9_:]*)
    \s*\(
       ([^)]*)
    \)
    \s*->\s*
    ([A-Za-z_][A-Za-z0-9_:\?<>\*\&]+)
    """#)

    // MARK: - Python

    /// Python variable: `name: Type`
    /// Output: (wholeMatch, varName, typeName)
    nonisolated(unsafe) static let pythonVariableRegex: Regex<(Substring, Substring, Substring)> =
        #/^([A-Za-z_]\w*)\s*:\s*([A-Za-z_][A-Za-z0-9_\.\[\]\|]*)/#

    /// Python function: `(async )?def name(params)( -> returnType)?:`
    /// Output: (wholeMatch, funcName, paramList, returnType?)
    nonisolated(unsafe) static let pythonFunctionRegex: Regex<(Substring, Substring, Substring, Substring?)> =
        #/^(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\(([^)]*)\)(?:\s*->\s*([A-Za-z_][A-Za-z0-9_\.\[\]\|\,\(\)\{\}\s]*))?\s*:.*$/#

    // MARK: - JavaScript/TypeScript (basic patterns)

    /// JS/TS variable: `(var|let|const) name?: Type`
    /// Output: (wholeMatch, varName, typeName?)
    static let jsTsVariableRegex = CodeMapPCRE2Pattern(#"^[ \t]*(?:var|let|const)\s+([A-Za-z_]\w*\??)\s*(?::\s*([A-Za-z_][A-Za-z0-9_<>\|\[\]\(\)\{\}\&\?\.\-]*))?"#)

    /// JS/TS function: `(export)? (default)? (async)? function name<T>?(params): ReturnType?`
    /// Output: (wholeMatch, funcName, paramList, returnType?)
    static let jsTsFunctionRegex = CodeMapPCRE2Pattern(#"^[ \t]*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+([A-Za-z_]\w*\??)(?:<[^>]+>)?\s*\(([^)]*)\)(?:\s*:\s*([A-Za-z_][A-Za-z0-9_<>\|\[\]\(\)\{\}\&\?\.\-]*))?(?:\s*\{)?"#)

    /// TS arrow function pattern
    static let tsArrowFunctionRegex = CodeMapPCRE2Pattern(#"""
    (?xm)
    ^[ \t]*
    (?:export\s+)?(?:default\s+)?(?:async\s+)?
    (?:var|let|const)\s+
    ([A-Za-z_]\w*\??)
    (?:\s*:\s*
       (?:<[^>]+>\s*)?
       \([^)]*\)\s*=>\s*
       ([A-Za-z_][A-Za-z0-9_<>\|\[\]\(\)\{\}\&\?\.\-]*)
    )?
    \s*=\s*
    \(?[^)]*\)?\s*=>     # actual arrow
    (?:\s*\{)?
    """#)

    /// TS arrow function with params and return: `const name = (params): ReturnType =>`
    /// Output: (wholeMatch, funcName, paramList, returnType)
    static let tsArrowFunctionParamsReturnRegex = CodeMapPCRE2Pattern(#"^[ \t]*(?:export\s+)?(?:default\s+)?(?:async\s+)?(?:var|let|const)\s+([A-Za-z_]\w*\??)\s*=\s*\(([^)]*)\)\s*:\s*([A-Za-z_][A-Za-z0-9_<>\|\[\]\(\)\{\}\&\?\.\-\s,]*)\s*=>"#)

    /// TS type alias: `(export)? type Name = Type`
    /// Output: (wholeMatch, aliasName, rhsType)
    static let tsTypeAliasRegex = CodeMapPCRE2Pattern(#"^[ \t]*(?:export\s+)?(?:default\s+)?type\s+([A-Za-z_]\w*)\s*=\s*([A-Za-z_][A-Za-z0-9_<>\|\[\]\(\)\{\}\&\?\.\-]*)"#)

    /// TS variable: `(export)? (var|let|const) name?: Type`
    /// Output: (wholeMatch, varName, typeName?)
    static let tsVariableRegex = CodeMapPCRE2Pattern(#"^[ \t]*(?:export\s+)?(?:default\s+)?(?:async\s+)?(?:var|let|const)\s+([A-Za-z_]\w*\??)(?:\s*:\s*([A-Za-z_][A-Za-z0-9_<>\|\[\]\(\)\{\}\&\?\.\-]*))?"#)

    // MARK: - TSX

    /// Very similar to TS but we allow a generic in the name, e.g. "function FooComponent<T>()"
    static let tsxVariableRegex = CodeMapPCRE2Pattern(#"""
    (?xm)
    ^[ \t]*
    (?:export\s+)?(?:default\s+)?(?:async\s+)?
    (?:var|let|const)\s+
    ([A-Za-z_]\w*(?:<[^>]*>)?\??)
    (?:\s*:\s*
    ([A-Za-z_][A-Za-z0-9_<>\|\[\]\(\)\{\}\&\?\.\-]*))?
    """#)

    static let tsxFunctionRegex = CodeMapPCRE2Pattern(#"""
    (?xm)
    ^[ \t]*
    (?:export\s+)?(?:default\s+)?(?:async\s+)?
    function\s+
    ([A-Za-z_]\w*(?:<[^>]*>)?\??)
    \s*\(
       ([^)]*)
    \)
    (?:\s*:\s*
    ([A-Za-z_][A-Za-z0-9_<>\|\[\]\(\)\{\}\&\?\.\-]*))?
    (?:\s*\{)?
    """#)

    static let tsxArrowFunctionRegex = CodeMapPCRE2Pattern(#"""
    (?xm)
    ^[ \t]*
    (?:export\s+)?(?:default\s+)?(?:async\s+)?
    (?:var|let|const)\s+
    ([A-Za-z_]\w*(?:<[^>]*>)?\??)
    (?:\s*:\s*
       (?:<[^>]+>\s*)?
       \([^)]*\)\s*=>\s*
       ([A-Za-z_][A-Za-z0-9_<>\|\[\]\(\)\{\}\&\?\.\-]*)
    )?
    \s*=\s*
    \(?[^)]*\)?\s*=>     # arrow
    (?:\s*\{)?
    """#)

    // MARK: - TS class-level methods / properties

    static let tsClassMethodRegex = CodeMapPCRE2Pattern(#"""
    (?xm)
    ^[ \t]*
    (?:export\s+)?(?:default\s+)?
    (?:(?:public|private|protected|static|readonly|abstract|async|override)\s+)*
    ([A-Za-z_]\w*\??)
    \s*\(
       ([^)]*)
    \)
    (?:\s*:\s*
    ([A-Za-z_][A-Za-z0-9_<>\|\[\]\(\)\{\}\&\?\.\-]*))?
    (?:\s*\{)?
    """#)

    static let tsClassPropertyRegex = CodeMapPCRE2Pattern(#"""
    (?xm)
    ^[ \t]*
    (?:export\s+)?(?:default\s+)?
    (?:(?:public|private|protected|static|readonly|const)\s+)*
    ([A-Za-z_]\w*\??)
    \s*:\s*
    ([A-Za-z_][A-Za-z0-9_<>\|\[\]\(\)\{\}\&\?\.\-]*)
    """#)

    static let tsClassArrowMethodRegex = CodeMapPCRE2Pattern(#"""
    (?xm)
    ^[ \t]*
    (?:export\s+)?(?:default\s+)?
    (?:(?:public|private|protected|static|readonly|abstract|async)\s+)*
    ([A-Za-z_]\w*\??)
    \s*=\s*\(
       ([^)]*)
    \)
    (?:\s*:\s*
    ([A-Za-z_][A-Za-z0-9_<>\|\[\]\(\)\{\}\&\?\.\-]*))?
    \s*=>
    (?:\s*\{)?
    """#)

    static let tsClassArrowNoParensRegex = CodeMapPCRE2Pattern(#"""
    (?xm)
    ^[ \t]*
    (?:export\s+)?(?:default\s+)?
    (?:(?:public|private|protected|static|readonly|abstract|async)\s+)*
    ([A-Za-z_]\w*\??)
    \s*=\s*
    ([A-Za-z_]\w*)
    \s*:\s*
    ([A-Za-z_][A-Za-z0-9_<>\|\[\]\(\)\{\}\&\?\.\-]*)
    \s*=>
    (?:\s*\{)?
    """#)

    static let tsConstructorRegex = CodeMapPCRE2Pattern(#"""
    (?xm)
    ^[ \t]*
    (?:(?:public|private|protected)\s+)?
    constructor\s*\(
       ([^)]*)
    \)
    (?:\s*\{)?
    """#)

    static let tsAccessorRegex = CodeMapPCRE2Pattern(#"""
    (?xm)
    ^[ \t]*
    (?:export\s+)?(?:default\s+)?
    (?:(?:public|private|protected|static)\s+)*
    (get|set)\s+
    ([A-Za-z_]\w*\??)
    (?:\s*\(([^)]*)\))?
    (?:\s*:\s*
    ([A-Za-z_][A-Za-z0-9_<>\|\[\]\(\)\{\}\&\?\.\-]*))?
    (?:\s*\{)?
    """#)

    // MARK: - Go

    nonisolated(unsafe) static let goVariableRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^
    (?:var|const)\s+
    ([A-Za-z_]\w*)
    (?:
    	\s+([A-Za-z_][A-Za-z0-9_\.\*\[\]]*)  # optional explicit type
    )?
    (?:\s*=\s*[^;]+)?
    """#)

    nonisolated(unsafe) static let goFunctionRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^
    func\s+
    (?:\([^)]*\)\s+)?        # optional receiver
    ([A-Za-z_]\w*)
    \s*\(
       ([^)]*)
    \)
    \s*
    (
     \([^\)]*\)
     |
     [A-Za-z_][A-Za-z0-9_\.\*\[\]]*
    )?
    """#)

    // MARK: - Rust

    nonisolated(unsafe) static let rustVariableRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^
    let\s+(?:mut\s+)?
    ([A-Za-z_]\w*)
    (?:
    	\s*:\s*([A-Za-z_][A-Za-z0-9_<>:\?\*\&]+)
    )?
    (?:\s*=\s*[^;]+)?
    """#)

    nonisolated(unsafe) static let rustFunctionRegex: Regex<AnyRegexOutput> = try! Regex(#"""
    (?xm)
    ^
    (?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?
    fn\s+
    ([A-Za-z_]\w*)             # group(1): function name
    \s*\(
       ([^)]*)                 # group(2): param list
    \)
    (?:\s*->\s*
       ([A-Za-z_][A-Za-z0-9_:\&]*)
    )?
    \s*\{?
    .*$
    """#)

    // MARK: - Inline Regex Helpers (typed outputs for compile-time safety)

    /// C-style parameter decorators to remove (out, ref, in, const, etc.)
    /// Output: (wholeMatch, decorator)
    private nonisolated(unsafe) static let cStyleDecoratorRegex: Regex<(Substring, Substring)> = #/\b(out|ref|in|const|volatile|mutable|inout|__owned|__borrowed)\b/#

    /// Match last whitespace-separated word (for separating type from name)
    /// Output: wholeMatch only
    private nonisolated(unsafe) static let lastWordSeparatorRegex: Regex<Substring> = #/\s+[^\s]+$/#

    /// Swift parameter decorators to remove (inout, __owned, etc.)
    /// Output: (wholeMatch, decorator)
    private nonisolated(unsafe) static let swiftDecoratorRegex: Regex<(Substring, Substring)> = #/\b(inout|__owned|__shared|__borrowed)\b/#

    /// Rust parameter decorators to remove (mut, ref)
    /// Output: (wholeMatch, decorator)
    private nonisolated(unsafe) static let rustDecoratorRegex: Regex<(Substring, Substring)> = #/\b(mut|ref)\b/#

    /// Multiple whitespace to normalize to single space
    /// Output: wholeMatch only
    private nonisolated(unsafe) static let multiWhitespaceRegex: Regex<Substring> = #/\s+/#

    private static func normalizeWhitespaceRun(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var previousWasWhitespace = true
        for ch in text {
            if ch.isWhitespace {
                if !previousWasWhitespace {
                    out.append(" ")
                    previousWasWhitespace = true
                }
            } else {
                out.append(ch)
                previousWasWhitespace = false
            }
        }
        if out.last == " " {
            out.removeLast()
        }
        return out
    }

    // MARK: - Public API for variables

    /// Generic entry point for variable lines. Returns ["name":..., "type":...].
    static func matchAnyVariableLine(
        _ line: String,
        language: LanguageType,
        stats: CodeMapPerformanceCollector? = nil
    ) -> [String: String]? {
        stats?.lteMatchAnyVariableCalls += 1
        let start = stats == nil ? 0 : CFAbsoluteTimeGetCurrent()
        defer {
            if let stats, start != 0 {
                stats.languageTypeExtractorVariableDuration += (CFAbsoluteTimeGetCurrent() - start)
            }
        }
        switch language {
        case .ts:
            // 1) type alias => "type Name = Something"
            if let m = tsTypeAliasRegex.firstMatch(in: line), let name = capture(m, at: 1) {
                let rhsType = extractTSTypeAliasRHS(from: line) ?? capture(m, at: 2) ?? ""
                return [
                    "name": name,
                    "type": rhsType
                ]
            }
            // 2) class/interface property (no var/let/const)
            if let m = tsClassPropertyRegex.firstMatch(in: line) {
                var result = [String: String]()
                if let name = capture(m, at: 1) {
                    result["name"] = name
                }
                if let typeName = extractTSTypeAnnotation(from: line) {
                    result["type"] = typeName
                }
                return result.isEmpty ? nil : result
            }
            // 2) normal TS var
            if let m = tsVariableRegex.firstMatch(in: line), let name = capture(m, at: 1) {
                var result = ["name": name]
                if let typeName = extractTSTypeAnnotation(from: line) ?? capture(m, at: 2) {
                    result["type"] = typeName.trimmingCharacters(in: .whitespaces)
                }
                return result
            }
            // 3) fallback to jsTs
            if let m = jsTsVariableRegex.firstMatch(in: line), let name = capture(m, at: 1) {
                var result = ["name": name]
                if let typeName = extractTSTypeAnnotation(from: line) ?? capture(m, at: 2) {
                    result["type"] = typeName.trimmingCharacters(in: .whitespaces)
                }
                return result
            }
            return nil

        case .php, .ruby:
            return nil // PHP/Ruby handled purely by AST captures
        case .tsx:
            // same approach for TSX
            if let m = tsTypeAliasRegex.firstMatch(in: line), let name = capture(m, at: 1) {
                let rhsType = extractTSTypeAliasRHS(from: line) ?? capture(m, at: 2) ?? ""
                return [
                    "name": name,
                    "type": rhsType
                ]
            }
            if let m = tsClassPropertyRegex.firstMatch(in: line) {
                var result = [String: String]()
                if let name = capture(m, at: 1) {
                    result["name"] = name
                }
                if let typeName = extractTSTypeAnnotation(from: line) {
                    result["type"] = typeName
                }
                return result.isEmpty ? nil : result
            }
            if let m = tsxVariableRegex.firstMatch(in: line) {
                var result = extractVarMatch(match: m, groupName1: 1, groupName2: 2) ?? [:]
                if let typeName = extractTSTypeAnnotation(from: line) {
                    result["type"] = typeName
                }
                return result.isEmpty ? nil : result
            }
            // fallback
            if let m = jsTsVariableRegex.firstMatch(in: line), let name = capture(m, at: 1) {
                var result = ["name": name]
                if let typeName = extractTSTypeAnnotation(from: line) ?? capture(m, at: 2) {
                    result["type"] = typeName.trimmingCharacters(in: .whitespaces)
                }
                return result
            }
            return nil

        case .swift:
            if let m = swiftVariableRegex.firstMatch(in: line) {
                var result = [String: String]()
                if let name = capture(m, at: 1) {
                    result["name"] = name
                }
                if let type = capture(m, at: 2) {
                    result["type"] = type
                }
                return result.isEmpty ? nil : result
            }
            return nil

        case .c_sharp:
            if let m = line.firstMatch(of: cSharpVariableRegex) {
                var result = [String: String]()
                if let type = capture(m, at: 1) {
                    result["type"] = type
                }
                if let name = capture(m, at: 2) {
                    result["name"] = name
                }
                return result.isEmpty ? nil : result
            }
            return nil

        case .java:
            if let m = line.firstMatch(of: javaVariableRegex) {
                var result = [String: String]()
                if let type = capture(m, at: 1) {
                    result["type"] = type
                }
                if let name = capture(m, at: 2) {
                    result["name"] = name
                }
                return result.isEmpty ? nil : result
            }
            return nil

        case .dart:
            if let m = line.firstMatch(of: dartVariableRegex) {
                // group(1,2) or group(3,4)
                if let type = capture(m, at: 1), let name = capture(m, at: 2) {
                    return ["type": type, "name": name]
                } else if m.output.count >= 5,
                          let type = capture(m, at: 3),
                          let name = capture(m, at: 4)
                {
                    return ["type": type, "name": name]
                }
            }
            return nil

        case .python:
            if let m = line.firstMatch(of: pythonVariableRegex) {
                // Typed regex: (wholeMatch, varName, typeName)
                return [
                    "name": String(m.1).trimmingCharacters(in: .whitespaces),
                    "type": String(m.2).trimmingCharacters(in: .whitespaces)
                ]
            }
            return nil

        case .js:
            if let m = jsTsVariableRegex.firstMatch(in: line), let name = capture(m, at: 1) {
                var result = ["name": name]
                if let typeName = capture(m, at: 2) {
                    result["type"] = typeName.trimmingCharacters(in: .whitespaces)
                }
                return result
            }
            return nil

        case .go:
            if let m = line.firstMatch(of: goVariableRegex) {
                var result = [String: String]()
                if let name = capture(m, at: 1) {
                    result["name"] = name
                }
                if let type = capture(m, at: 2) {
                    result["type"] = type
                }
                return result.isEmpty ? nil : result
            }
            return nil

        case .rust:
            if let m = line.firstMatch(of: rustVariableRegex) {
                var result = [String: String]()
                if let name = capture(m, at: 1) {
                    result["name"] = name
                }
                if let type = capture(m, at: 2) {
                    result["type"] = type
                }
                return result.isEmpty ? nil : result
            }
            return nil

        case .c:
            if let m = line.firstMatch(of: cVariableRegex) {
                var result = [String: String]()
                if let type = capture(m, at: 1) {
                    result["type"] = type
                }
                if let name = capture(m, at: 2) {
                    result["name"] = name
                }
                return result.isEmpty ? nil : result
            }
            return nil

        case .cpp:
            if let m = line.firstMatch(of: cppVariableRegex) {
                var result = [String: String]()
                if let type = capture(m, at: 1) {
                    result["type"] = type
                }
                if let name = capture(m, at: 2) {
                    result["name"] = name
                }
                return result.isEmpty ? nil : result
            }
            return nil
        }
    }

    // MARK: - Public API for function lines

    struct FunctionLineMatch {
        let name: String?
        let paramList: String?
        let returnType: String?
        let parameterTypes: [String]?

        func asDictionary(language: LanguageType) -> [String: String] {
            var dict: [String: String] = [:]
            if let name, !name.isEmpty { dict["name"] = name }
            if let paramList, !paramList.isEmpty { dict["paramList"] = paramList }
            if let returnType, !returnType.isEmpty { dict["returnType"] = returnType }
            if let parameterTypes, !parameterTypes.isEmpty {
                let joined = parameterTypes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: ", ")
                dict["parameterTypes"] = joined
            } else if dict["paramList"] != nil {
                dict = dict.thenParseParameters(language: language)
            }
            return dict
        }
    }

    private enum TSLineKind {
        case constructor
        case accessor
        case functionKeyword
        case arrowAssigned
        case arrowFunction
        case methodLike
        case unknown
    }

    private static func firstTopLevelIndex(
        of char: Character,
        in text: String,
        startingAt start: String.Index? = nil
    ) -> String.Index? {
        var angleDepth = 0
        var parenDepth = 0
        var braceDepth = 0
        var bracketDepth = 0
        var i = start ?? text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            switch ch {
            case "<": angleDepth += 1
            case ">": angleDepth = max(0, angleDepth - 1)
            case "(": parenDepth += 1
            case ")": parenDepth = max(0, parenDepth - 1)
            case "{": braceDepth += 1
            case "}": braceDepth = max(0, braceDepth - 1)
            case "[": bracketDepth += 1
            case "]": bracketDepth = max(0, bracketDepth - 1)
            default: break
            }
            if angleDepth == 0, parenDepth == 0, braceDepth == 0, bracketDepth == 0, ch == char {
                return i
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func firstTopLevelIndex(
        ofAny chars: Set<Character>,
        in text: String,
        startingAt start: String.Index? = nil
    ) -> String.Index? {
        var angleDepth = 0
        var parenDepth = 0
        var braceDepth = 0
        var bracketDepth = 0
        var i = start ?? text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            switch ch {
            case "<": angleDepth += 1
            case ">": angleDepth = max(0, angleDepth - 1)
            case "(": parenDepth += 1
            case ")": parenDepth = max(0, parenDepth - 1)
            case "{": braceDepth += 1
            case "}": braceDepth = max(0, braceDepth - 1)
            case "[": bracketDepth += 1
            case "]": bracketDepth = max(0, bracketDepth - 1)
            default: break
            }
            if angleDepth == 0, parenDepth == 0, braceDepth == 0, bracketDepth == 0, chars.contains(ch) {
                return i
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func firstTopLevelAssignmentEquals(
        in text: String,
        startingAt start: String.Index? = nil
    ) -> String.Index? {
        var angleDepth = 0
        var parenDepth = 0
        var braceDepth = 0
        var bracketDepth = 0
        var i = start ?? text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            switch ch {
            case "<": angleDepth += 1
            case ">": angleDepth = max(0, angleDepth - 1)
            case "(": parenDepth += 1
            case ")": parenDepth = max(0, parenDepth - 1)
            case "{": braceDepth += 1
            case "}": braceDepth = max(0, braceDepth - 1)
            case "[": bracketDepth += 1
            case "]": bracketDepth = max(0, bracketDepth - 1)
            case "=":
                if angleDepth == 0, parenDepth == 0, braceDepth == 0, bracketDepth == 0 {
                    let next = text.index(after: i)
                    if next < text.endIndex {
                        let nextChar = text[next]
                        if nextChar == ">" || nextChar == "=" {
                            i = next
                            continue
                        }
                    }
                    return i
                }
            default: break
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func findTopLevelSubstring(
        _ needle: String,
        in text: String,
        startingAt start: String.Index? = nil
    ) -> String.Index? {
        guard !needle.isEmpty else { return nil }
        let needleChars = Array(needle)
        var angleDepth = 0
        var parenDepth = 0
        var braceDepth = 0
        var bracketDepth = 0
        var i = start ?? text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            switch ch {
            case "<": angleDepth += 1
            case ">": angleDepth = max(0, angleDepth - 1)
            case "(": parenDepth += 1
            case ")": parenDepth = max(0, parenDepth - 1)
            case "{": braceDepth += 1
            case "}": braceDepth = max(0, braceDepth - 1)
            case "[": bracketDepth += 1
            case "]": bracketDepth = max(0, bracketDepth - 1)
            default: break
            }
            if angleDepth == 0, parenDepth == 0, braceDepth == 0, bracketDepth == 0 {
                if ch == needleChars.first,
                   let endIndex = text.index(i, offsetBy: needleChars.count, limitedBy: text.endIndex)
                {
                    let candidate = text[i ..< endIndex]
                    if candidate.elementsEqual(needleChars) {
                        return i
                    }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func findMatchingParen(in text: String, startIndex: String.Index) -> String.Index? {
        var depth = 0
        var i = startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func findMatchingBrace(in text: String, startIndex: String.Index) -> String.Index? {
        var depth = 0
        var i = startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func trimTSType(_ typeText: Substring) -> String? {
        var cleaned = String(typeText).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("{"),
           let endIndex = findMatchingBrace(in: cleaned, startIndex: cleaned.startIndex)
        {
            cleaned = String(cleaned[...endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !cleaned.hasPrefix("{"),
           let braceIndex = firstTopLevelIndex(of: "{", in: cleaned)
        {
            let beforeBrace = String(cleaned[..<braceIndex])
            if firstTopLevelIndex(ofAny: ["&", "|"], in: beforeBrace) == nil {
                cleaned = beforeBrace.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let endIndex = firstTopLevelIndex(of: ";", in: cleaned) {
            cleaned = String(cleaned[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let last = cleaned.last, last == "&" || last == "|" {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func normalizeTSLine(_ line: String) -> String {
        normalizeWhitespaceRun(line)
    }

    fileprivate static func extractTSReturnType(from signature: String, stats: CodeMapPerformanceCollector? = nil) -> String? {
        let trimmed = normalizeTSLine(signature)
        guard !trimmed.isEmpty else { return nil }
        let hasFunctionKeyword = trimmed.range(of: #"\bfunction\b"#, options: .regularExpression) != nil
        let arrowRange = hasFunctionKeyword ? nil : TopLevelScanner.firstTopLevelRange(of: "=>", in: trimmed, track: .all)
        let endIndex = arrowRange?.lowerBound ?? trimmed.endIndex

        if let openParen = firstTopLevelIndex(of: "(", in: trimmed),
           let closeParen = findMatchingParen(in: trimmed, startIndex: openParen)
        {
            let searchStart = trimmed.index(after: closeParen)
            if let colon = firstTopLevelIndex(of: ":", in: trimmed, startingAt: searchStart),
               colon < endIndex
            {
                let typeStart = trimmed.index(after: colon)
                let result = trimTSType(trimmed[typeStart ..< endIndex])
                if result != nil {
                    stats?.tsReturnTypeFastPathHits += 1
                }
                return result
            }
        }

        if let colon = firstTopLevelIndex(of: ":", in: trimmed),
           colon < endIndex
        {
            let typeStart = trimmed.index(after: colon)
            let result = trimTSType(trimmed[typeStart ..< endIndex])
            if result != nil {
                stats?.tsReturnTypeFastPathHits += 1
            }
            return result
        }
        return nil
    }

    fileprivate static func extractTSTypeAnnotation(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = firstTopLevelIndex(of: ":", in: trimmed) else { return nil }
        let typeStart = trimmed.index(after: colon)
        let eqIndex = firstTopLevelAssignmentEquals(in: trimmed, startingAt: typeStart)
        let semiIndex = firstTopLevelIndex(of: ";", in: trimmed, startingAt: typeStart)
        var endIndex = trimmed.endIndex
        if let eqIndex, eqIndex < endIndex { endIndex = eqIndex }
        if let semiIndex, semiIndex < endIndex { endIndex = semiIndex }
        return trimTSType(trimmed[typeStart ..< endIndex])
    }

    fileprivate static func extractTSTypeAliasRHS(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let eqIndex = firstTopLevelIndex(of: "=", in: trimmed) else { return nil }
        let typeStart = trimmed.index(after: eqIndex)
        let endIndex = firstTopLevelIndex(ofAny: [";"], in: trimmed, startingAt: typeStart) ?? trimmed.endIndex
        return trimTSType(trimmed[typeStart ..< endIndex])
    }

    private static func stripTSLeadingModifiers(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let modifiers = [
            "export", "default", "public", "private", "protected",
            "static", "readonly", "abstract", "async", "override"
        ]
        var foundModifier = true
        while foundModifier {
            foundModifier = false
            for mod in modifiers {
                if trimmed.hasPrefix("\(mod) ") {
                    trimmed = trimmed.dropFirst(mod.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                    foundModifier = true
                    break
                }
            }
        }
        return trimmed
    }

    private static func classifyTSFunctionLine(_ line: String) -> TSLineKind {
        let trimmed = stripTSLeadingModifiers(line)
        if trimmed.hasPrefix("constructor") {
            return .constructor
        }
        if trimmed.hasPrefix("get ") || trimmed.hasPrefix("set ") {
            return .accessor
        }
        if trimmed.hasPrefix("function") || trimmed.contains("function ") {
            return .functionKeyword
        }
        if trimmed.contains("=>") {
            if trimmed.contains("=") {
                return .arrowAssigned
            }
            return .arrowFunction
        }
        if trimmed.isEmpty {
            return .unknown
        }
        return .methodLike
    }

    /// Generic entry point for function lines. Returns a dictionary with keys
    /// ["name":..., "returnType":..., "paramList":..., "parameterTypes":...].
    static func matchAnyFunctionLineParsed(
        _ line: String,
        language: LanguageType,
        stats: CodeMapPerformanceCollector? = nil
    ) -> FunctionLineMatch? {
        stats?.lteMatchAnyFunctionCalls += 1
        let start = stats == nil ? 0 : CFAbsoluteTimeGetCurrent()
        defer {
            if let stats, start != 0 {
                stats.languageTypeExtractorFunctionDuration += (CFAbsoluteTimeGetCurrent() - start)
            }
        }
        switch language {
        case .ts, .tsx:
            let kind = classifyTSFunctionLine(line)
            let isTSX = (language == .tsx)
            let parsedReturnType = extractTSReturnType(from: line, stats: stats)

            switch kind {
            case .constructor:
                if let m = tsConstructorRegex.firstMatch(in: line) {
                    if isTSX {
                        stats?.tsxConstructorMatches += 1
                    } else {
                        stats?.tsConstructorMatches += 1
                    }
                    let paramList = capture(m, at: 1)
                    let paramTypes = paramList.map { LanguageTypeExtractor.parseTSParameterList($0) }
                    return FunctionLineMatch(
                        name: "constructor",
                        paramList: paramList,
                        returnType: nil,
                        parameterTypes: paramTypes
                    )
                }
                return nil

            case .accessor:
                if let m = tsAccessorRegex.firstMatch(in: line) {
                    if isTSX {
                        stats?.tsxAccessorMatches += 1
                    } else {
                        stats?.tsAccessorMatches += 1
                    }
                    let prefix = capture(m, at: 1)
                    let name = capture(m, at: 2)
                    let paramList = capture(m, at: 3)
                    let returnType = parsedReturnType ?? capture(m, at: 4)
                    let paramTypes = paramList.map { LanguageTypeExtractor.parseTSParameterList($0) }
                    let fullName = [prefix, name].compactMap(\.self).joined(separator: " ")
                    return FunctionLineMatch(
                        name: fullName.isEmpty ? nil : fullName,
                        paramList: paramList,
                        returnType: returnType,
                        parameterTypes: paramTypes
                    )
                }
                return nil

            case .functionKeyword:
                if isTSX, let m = tsxFunctionRegex.firstMatch(in: line) {
                    stats?.tsxClassMethodMatches += 1
                    let name = capture(m, at: 1)
                    let paramList = capture(m, at: 2)
                    let returnType = parsedReturnType ?? capture(m, at: 3)
                    let paramTypes = paramList.map { LanguageTypeExtractor.parseTSParameterList($0) }
                    return FunctionLineMatch(
                        name: name,
                        paramList: paramList,
                        returnType: returnType,
                        parameterTypes: paramTypes
                    )
                }
                if let m = jsTsFunctionRegex.firstMatch(in: line), let name = capture(m, at: 1), let paramList = capture(m, at: 2) {
                    if isTSX {
                        stats?.tsxClassMethodMatches += 1
                    } else {
                        stats?.tsClassMethodMatches += 1
                    }
                    let returnType = parsedReturnType ?? capture(m, at: 3)
                    let paramTypes = LanguageTypeExtractor.parseTSParameterList(paramList)
                    return FunctionLineMatch(
                        name: name,
                        paramList: paramList,
                        returnType: returnType,
                        parameterTypes: paramTypes
                    )
                }
                return nil

            case .arrowAssigned:
                if let m = tsClassArrowMethodRegex.firstMatch(in: line) {
                    if isTSX {
                        stats?.tsxClassArrowMatches += 1
                    } else {
                        stats?.tsClassArrowMatches += 1
                    }
                    let name = capture(m, at: 1)
                    let paramList = capture(m, at: 2)
                    let returnType = parsedReturnType ?? capture(m, at: 3)
                    let paramTypes = paramList.map { LanguageTypeExtractor.parseTSParameterList($0) }
                    return FunctionLineMatch(
                        name: name,
                        paramList: paramList,
                        returnType: returnType,
                        parameterTypes: paramTypes
                    )
                }
                if let m = tsClassArrowNoParensRegex.firstMatch(in: line) {
                    if isTSX {
                        stats?.tsxClassArrowNoParensMatches += 1
                    } else {
                        stats?.tsClassArrowNoParensMatches += 1
                    }
                    let name = capture(m, at: 1)
                    let paramName = capture(m, at: 2)
                    let paramType = capture(m, at: 3)
                    let paramList = (paramName != nil && paramType != nil) ? "\(paramName!): \(paramType!)" : nil
                    return FunctionLineMatch(
                        name: name,
                        paramList: paramList,
                        returnType: parsedReturnType,
                        parameterTypes: paramType.map { [$0] }
                    )
                }
                fallthrough

            case .arrowFunction:
                if isTSX, let m = tsxArrowFunctionRegex.firstMatch(in: line) {
                    stats?.tsxArrowFunctionMatches += 1
                    let name = capture(m, at: 1)
                    let returnType = parsedReturnType ?? capture(m, at: 2)
                    return FunctionLineMatch(
                        name: name,
                        paramList: nil,
                        returnType: returnType,
                        parameterTypes: nil
                    )
                }
                if let m = tsArrowFunctionRegex.firstMatch(in: line) {
                    if isTSX {
                        stats?.tsxArrowFunctionMatches += 1
                    } else {
                        stats?.tsArrowFunctionMatches += 1
                    }
                    let name = capture(m, at: 1)
                    let returnType = parsedReturnType ?? capture(m, at: 2)
                    return FunctionLineMatch(
                        name: name,
                        paramList: nil,
                        returnType: returnType,
                        parameterTypes: nil
                    )
                }
                if let m2 = tsArrowFunctionParamsReturnRegex.firstMatch(in: line), let name = capture(m2, at: 1), let paramList = capture(m2, at: 2) {
                    if isTSX {
                        stats?.tsxArrowFunctionParamsReturnMatches += 1
                    } else {
                        stats?.tsArrowFunctionParamsReturnMatches += 1
                    }
                    let returnType = parsedReturnType ?? capture(m2, at: 3)
                    let paramTypes = LanguageTypeExtractor.parseTSParameterList(paramList)
                    return FunctionLineMatch(
                        name: name,
                        paramList: paramList,
                        returnType: returnType,
                        parameterTypes: paramTypes
                    )
                }
                return nil

            case .methodLike:
                if let m = tsClassMethodRegex.firstMatch(in: line) {
                    if isTSX {
                        stats?.tsxClassMethodMatches += 1
                    } else {
                        stats?.tsClassMethodMatches += 1
                    }
                    let dict = extractNamedGroups(
                        match: m,
                        groupNames: ("name", "paramList", "returnType"),
                        indices: (1, 2, 3)
                    )
                    let name = dict["name"]
                    let paramList = dict["paramList"]
                    let returnType = parsedReturnType ?? dict["returnType"]
                    let paramTypes = paramList.map { LanguageTypeExtractor.parseTSParameterList($0) }
                    return FunctionLineMatch(
                        name: name,
                        paramList: paramList,
                        returnType: returnType,
                        parameterTypes: paramTypes
                    )
                }
                return nil

            case .unknown:
                return nil
            }

        default:
            return nil
        }
    }

    static func matchAnyFunctionLine(
        _ line: String,
        language: LanguageType,
        stats: CodeMapPerformanceCollector? = nil
    ) -> [String: String]? {
        if !(language == .ts || language == .tsx) {
            stats?.lteMatchAnyFunctionCalls += 1
        }
        let shouldMeasure = stats != nil && !(language == .ts || language == .tsx)
        let start = shouldMeasure ? CFAbsoluteTimeGetCurrent() : 0
        defer {
            if let stats, start != 0, shouldMeasure {
                stats.languageTypeExtractorFunctionDuration += (CFAbsoluteTimeGetCurrent() - start)
            }
        }

        switch language {
        // -------------------------------------------------------------------
        // TypeScript
        case .ts:
            if let parsed = matchAnyFunctionLineParsed(line, language: language, stats: stats) {
                return parsed.asDictionary(language: language)
            }
            return nil

        // -------------------------------------------------------------------
        // TSX
        case .tsx:
            if let parsed = matchAnyFunctionLineParsed(line, language: language, stats: stats) {
                return parsed.asDictionary(language: language)
            }
            return nil

        // -------------------------------------------------------------------
        // Swift
        case .swift:
            if let m = swiftFunctionRegex.firstMatch(in: line) {
                var result = [String: String]()
                if let val = capture(m, at: 1) {
                    result["name"] = val
                }
                if let val = capture(m, at: 2) {
                    result["paramList"] = val
                }
                if let val = capture(m, at: 3) {
                    result["returnType"] = val
                }
                return result.thenParseParameters(language: language)
            }
            return nil

        case .c_sharp:
            if let m = line.firstMatch(of: cSharpFunctionRegex) {
                let extracted = extractNamedGroups(
                    match: m,
                    groupNames: ("returnType", "name", "paramList"),
                    indices: (1, 2, 3)
                )
                return extracted.thenParseParameters(language: language)
            }
            return nil

        case .java:
            if let m = line.firstMatch(of: javaFunctionRegex) {
                let extracted = extractNamedGroups(
                    match: m,
                    groupNames: ("returnType", "name", "paramList"),
                    indices: (1, 2, 3)
                )
                return extracted.thenParseParameters(language: language)
            }
            return nil

        case .dart:
            if let m = line.firstMatch(of: dartGetterSetterRegex) {
                var result = [String: String]()
                if let val = capture(m, at: 1) {
                    result["returnType"] = val
                }
                if let val = capture(m, at: 3) {
                    result["name"] = val
                }
                if let val = capture(m, at: 4) {
                    result["paramList"] = val
                }
                return result.thenParseParameters(language: language)
            }
            if let m = line.firstMatch(of: dartFactoryRegex) {
                var result = [String: String]()
                if let val = capture(m, at: 1) {
                    result["name"] = val.split(separator: ".").last.map(String.init) ?? val
                }
                if let val = capture(m, at: 2) {
                    result["paramList"] = val
                }
                return result.thenParseParameters(language: language)
            }
            if let m = line.firstMatch(of: dartFunctionRegex) {
                var result = [String: String]()

                // returnType in group(1)
                if let val = capture(m, at: 1) {
                    result["returnType"] = val
                }

                // function name in group(2)
                if let val = capture(m, at: 2) {
                    result["name"] = val
                }

                // parameter list in group(3)
                if let val = capture(m, at: 3) {
                    result["paramList"] = val
                }

                // Then parse paramList into parameterTypes
                return result.thenParseParameters(language: language)
            }
            return nil

        case .python:
            if let m = line.firstMatch(of: pythonFunctionRegex) {
                // Typed regex: (wholeMatch, funcName, paramList, returnType?)
                var result = [String: String]()
                result["name"] = String(m.1).trimmingCharacters(in: .whitespaces)
                result["paramList"] = String(m.2).trimmingCharacters(in: .whitespaces)
                if let returnType = m.3 {
                    result["returnType"] = String(returnType).trimmingCharacters(in: .whitespaces)
                }
                return result.thenParseParameters(language: language)
            }
            return nil

        case .js:
            if let m = jsTsFunctionRegex.firstMatch(in: line), let name = capture(m, at: 1), let paramList = capture(m, at: 2) {
                var result = [
                    "name": name,
                    "paramList": paramList
                ]
                if let returnType = capture(m, at: 3) {
                    result["returnType"] = returnType
                }
                return result.thenParseParameters(language: language)
            }
            if let m = tsArrowFunctionRegex.firstMatch(in: line) {
                var arrowResult = [String: String]()
                if let val = capture(m, at: 1) {
                    arrowResult["name"] = val
                }
                if let val = capture(m, at: 2) {
                    arrowResult["returnType"] = val
                }
                return arrowResult
            }
            return nil

        case .go:
            if let m = line.firstMatch(of: goFunctionRegex) {
                var dict = extractNamedGroups(
                    match: m,
                    groupNames: ("name", "paramList", "returnBlock"),
                    indices: (1, 2, 3)
                )

                // Instead of the default parseCStyleParameterList(...) call, do parseGoParameterList:
                if let paramList = dict["paramList"] {
                    let paramTypes = parseGoParameterList(paramList)
                    dict["parameterTypes"] = paramTypes.joined(separator: ", ")
                }
                // tidy up return type if needed, etc.
                return dict
            }
            return nil

        case .rust:
            if let m = line.firstMatch(of: rustFunctionRegex) {
                var result = [String: String]()
                if let val = capture(m, at: 1) {
                    result["name"] = val
                }
                if let val = capture(m, at: 2) {
                    result["paramList"] = val
                }
                // optional trailing return
                if let val = capture(m, at: 3) {
                    result["returnType"] = val
                }
                return result.thenParseParameters(language: language)
            }
            return nil

        case .c:
            if let m = line.firstMatch(of: cFunctionRegex) {
                let extracted = extractNamedGroups(
                    match: m,
                    groupNames: ("returnType", "name", "paramList"),
                    indices: (1, 2, 3)
                )
                return extracted.thenParseParameters(language: language)
            }
            return nil

        case .cpp:
            // constructor (no return type)
            if let m = line.firstMatch(of: cppConstructorRegex) {
                var result = [String: String]()
                if let val = capture(m, at: 1) {
                    result["name"] = val.split(separator: "::").last.map(String.init) ?? val
                }
                if let val = capture(m, at: 2) {
                    result["paramList"] = val
                }
                return result.thenParseParameters(language: language)
            }
            // normal function
            if let m = line.firstMatch(of: cppFunctionRegex) {
                let extracted = extractNamedGroups(
                    match: m,
                    groupNames: ("returnType", "name", "paramList"),
                    indices: (1, 2, 3)
                )
                return extracted.thenParseParameters(language: language)
            }
            // trailing-return
            if let m = line.firstMatch(of: cppTrailingReturnFunctionRegex) {
                var result = [String: String]()
                if let val = capture(m, at: 1) {
                    result["name"] = val
                }
                if let val = capture(m, at: 2) {
                    result["paramList"] = val
                }
                if let val = capture(m, at: 3) {
                    result["returnType"] = val
                }
                return result.thenParseParameters(language: language)
            }
            return nil

        case .php, .ruby:
            // PHP/Ruby function extraction is handled by AST captures, not regex
            return nil
        }
    }

    fileprivate static func parseGoParameterList(_ paramList: String) -> [String] {
        // "func foo(a, b int, s string)" => paramList == "a, b int, s string"
        //  => after splitting by commas => ["a, b int", "s string"]

        let chunks = paramList
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var results = [String]()
        var pendingNames = [String]()

        for chunk in chunks {
            // chunk might look like "a, b int" or "id string" or "version int"
            // 1) remove any "=defaultValue" (Go usually doesn't do defaults, but let's be safe)
            let noDefault = chunk.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) ?? chunk

            // 2) split the remainder by whitespace => tokens
            //    e.g. "a, b int" -> ["a,", "b", "int"]
            var tokens = noDefault
                .split(whereSeparator: \.isWhitespace)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            if tokens.count >= 2 {
                let last = tokens.removeLast()
                let goType = stripTrailingCommasAndParens(last)

                let nameTokens = pendingNames + tokens.map { stripTrailingCommasAndParens($0) }
                for _ in nameTokens where !goType.isEmpty {
                    results.append(goType)
                }
                pendingNames.removeAll()
                continue
            }

            guard let only = tokens.first else {
                results.append("untyped")
                continue
            }

            let token = stripTrailingCommasAndParens(only)
            let looksLikeType = token.contains(".")
                || token.contains("*")
                || token.contains("[")
                || token.hasPrefix("map[")
                || token.hasPrefix("chan")
                || token.hasPrefix("func")
                || token.hasPrefix("...")

            if looksLikeType, pendingNames.isEmpty {
                results.append(token.isEmpty ? "untyped" : token)
            } else {
                pendingNames.append(token)
            }
        }

        if !pendingNames.isEmpty {
            results.append(contentsOf: pendingNames.map { _ in "untyped" })
        }

        return results
    }

    fileprivate static func stripTrailingCommasAndParens(_ s: String) -> String {
        var out = s
        // remove possible trailing punctuation like commas, parentheses
        while let lastChar = out.last, [",", "(", ")", ":"].contains(lastChar) {
            out.removeLast()
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Shared / Private Helpers (Swift Regex)

    /// Typealias for Swift Regex match result with dynamic output.
    typealias RegexMatch = Regex<AnyRegexOutput>.Match

    /// Extracts variable name and type from a regex match.
    /// - Parameters:
    ///   - match: The regex match result
    ///   - groupName1: Index of the capture group for "name"
    ///   - groupName2: Index of the capture group for "type"
    private static func extractVarMatch(
        match: RegexMatch,
        groupName1: Int,
        groupName2: Int
    ) -> [String: String]? {
        var result = [String: String]()
        if let capture1 = match.output[groupName1].substring {
            result["name"] = String(capture1).trimmingCharacters(in: .whitespaces)
        }
        if let capture2 = match.output[groupName2].substring {
            result["type"] = String(capture2).trimmingCharacters(in: .whitespaces)
        }
        return result.isEmpty ? nil : result
    }

    private static func extractVarMatch(
        match: CodeMapPCRE2Match,
        groupName1: Int,
        groupName2: Int
    ) -> [String: String]? {
        var result = [String: String]()
        if let capture1 = capture(match, at: groupName1) {
            result["name"] = capture1
        }
        if let capture2 = capture(match, at: groupName2) {
            result["type"] = capture2
        }
        return result.isEmpty ? nil : result
    }

    /// Checks if a capture group at the given index has a value.
    private static func matchHasGroup(_ match: RegexMatch, _ groupIndex: Int) -> Bool {
        groupIndex < match.output.count && match.output[groupIndex].substring != nil
    }

    /// Gets the captured substring at the given index, or nil if not captured.
    private static func capture(_ match: RegexMatch, at index: Int) -> String? {
        guard index < match.output.count,
              let substring = match.output[index].substring else { return nil }
        return String(substring).trimmingCharacters(in: .whitespaces)
    }

    /// Gets the captured substring at the given index from a PCRE2 match.
    private static func capture(_ match: CodeMapPCRE2Match, at index: Int) -> String? {
        match.trimmedCapture(index)
    }

    /// Extracts up to 3 named groups from a match, returning them in a dict.
    static func extractNamedGroups(
        match: RegexMatch,
        groupNames: (String, String, String),
        indices: (Int, Int, Int)
    ) -> [String: String] {
        var dict = [String: String]()
        let (g1Name, g2Name, g3Name) = groupNames
        let (i1, i2, i3) = indices

        if let val1 = capture(match, at: i1) {
            dict[g1Name] = val1
        }
        if let val2 = capture(match, at: i2) {
            dict[g2Name] = val2
        }
        if let val3 = capture(match, at: i3) {
            dict[g3Name] = val3
        }
        return dict
    }

    static func extractNamedGroups(
        match: CodeMapPCRE2Match,
        groupNames: (String, String, String),
        indices: (Int, Int, Int)
    ) -> [String: String] {
        var dict = [String: String]()
        let (g1Name, g2Name, g3Name) = groupNames
        let (i1, i2, i3) = indices

        if let val1 = capture(match, at: i1) {
            dict[g1Name] = val1
        }
        if let val2 = capture(match, at: i2) {
            dict[g2Name] = val2
        }
        if let val3 = capture(match, at: i3) {
            dict[g3Name] = val3
        }
        return dict
    }

    fileprivate static func parseCStyleParameterList(_ paramList: String) -> [String] {
        let chunks = paramList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var results = [String]()

        for chunk in chunks {
            if chunk.isEmpty { continue }
            // skip varargs
            if chunk.contains("...") {
                results.append("varargs")
                continue
            }
            // remove everything after '=' (default args)
            let maybeNoDefault = chunk.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) ?? chunk
            // remove decorators (out|ref|etc.)
            let cleaned = maybeNoDefault.replacing(cStyleDecoratorRegex, with: "")
                .trimmingCharacters(in: .whitespaces)

            // Attempt to separate type from name by the last space
            if let match = cleaned.firstMatch(of: lastWordSeparatorRegex) {
                let typePart = cleaned[..<match.range.lowerBound].trimmingCharacters(in: .whitespaces)
                if !typePart.isEmpty {
                    results.append(typePart)
                } else {
                    results.append(cleaned)
                }
            } else {
                results.append(cleaned)
            }
        }
        return results.filter { !$0.isEmpty }
    }

    fileprivate static func parseTSParameterList(_ paramList: String) -> [String] {
        let chunks = TopLevelScanner
            .splitTopLevel(paramList, separator: ",", track: .all)
            .map { paramList[$0].trimmingCharacters(in: .whitespaces) }
        var results = [String]()

        for chunk in chunks {
            if chunk.isEmpty { continue }
            var cleanChunk = chunk

            // Remove possible modifiers
            let modifiers = ["private", "public", "protected", "readonly", "abstract", "override"]
            var foundModifier = true
            while foundModifier {
                foundModifier = false
                for mod in modifiers {
                    if cleanChunk.hasPrefix("\(mod) ") {
                        cleanChunk = cleanChunk.dropFirst(mod.count + 1).trimmingCharacters(in: .whitespaces)
                        foundModifier = true
                        break
                    }
                }
            }

            // remove default
            let noDefault = cleanChunk.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) ?? cleanChunk

            // if there's a colon => that's the type
            if let colonIdx = TopLevelScanner.firstTopLevelIndex(of: ":", in: noDefault, track: .all) {
                if let questionIdx = TopLevelScanner.firstTopLevelIndex(of: "?", in: noDefault, track: .all),
                   questionIdx < colonIdx,
                   noDefault.index(after: questionIdx) != colonIdx
                {
                    // Conditional type - keep as-is
                    results.append(noDefault.trimmingCharacters(in: .whitespaces))
                } else {
                    let typePart = noDefault[noDefault.index(after: colonIdx)...]
                        .trimmingCharacters(in: .whitespaces)
                    results.append(typePart.isEmpty ? "any" : typePart)
                }
            } else {
                results.append("any")
            }
        }

        return results
    }

    fileprivate static func parseDartParameterList(_ paramList: String) -> [String] {
        let chunks = splitDartParameters(paramList)
        var results = [String]()

        for chunk in chunks {
            var cleaned = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty { continue }

            while cleaned.hasPrefix("{") || cleaned.hasPrefix("[") {
                cleaned.removeFirst()
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            while cleaned.hasSuffix("}") || cleaned.hasSuffix("]") {
                cleaned.removeLast()
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let modifiers = ["required", "final", "const", "covariant", "late"]
            var trimmed = cleaned
            var foundModifier = true
            while foundModifier {
                foundModifier = false
                for mod in modifiers {
                    if trimmed.hasPrefix("\(mod) ") {
                        trimmed = trimmed.dropFirst(mod.count + 1).trimmingCharacters(in: .whitespaces)
                        foundModifier = true
                        break
                    }
                }
            }

            let withoutDefault = splitDartDefault(trimmed)
            let withoutDefaultTrimmed = withoutDefault.trimmingCharacters(in: .whitespacesAndNewlines)
            if withoutDefaultTrimmed.hasPrefix("this.") || withoutDefaultTrimmed.hasPrefix("super.") {
                results.append("untyped")
                continue
            }

            let tokens = splitTopLevelTokens(withoutDefaultTrimmed)
            if tokens.count >= 2 {
                let typePart = tokens.dropLast().joined(separator: " ")
                if !typePart.isEmpty {
                    results.append(typePart)
                } else {
                    results.append("untyped")
                }
            } else if tokens.count == 1 {
                results.append("untyped")
            }
        }

        return results.filter { !$0.isEmpty }
    }

    fileprivate static func splitDartParameters(_ paramList: String) -> [String] {
        var results: [String] = []
        var current = ""
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var angleDepth = 0
        var inString: Character? = nil
        var escaped = false

        for ch in paramList {
            if let stringDelimiter = inString {
                current.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == stringDelimiter {
                    inString = nil
                }
                continue
            }

            if ch == "\"" || ch == "'" {
                inString = ch
                current.append(ch)
                continue
            }

            switch ch {
            case "(":
                parenDepth += 1
            case ")":
                parenDepth = max(0, parenDepth - 1)
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
            case "{":
                braceDepth += 1
            case "}":
                braceDepth = max(0, braceDepth - 1)
            case "<":
                angleDepth += 1
            case ">":
                angleDepth = max(0, angleDepth - 1)
            case ",":
                if parenDepth == 0, bracketDepth == 0, braceDepth == 0, angleDepth == 0 {
                    results.append(current)
                    current = ""
                    continue
                }
            default:
                break
            }
            current.append(ch)
        }

        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results.append(current)
        }
        return results
    }

    fileprivate static func splitDartDefault(_ param: String) -> String {
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var angleDepth = 0
        var inString: Character? = nil
        var escaped = false

        for (idx, ch) in param.enumerated() {
            if let stringDelimiter = inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == stringDelimiter {
                    inString = nil
                }
                continue
            }

            if ch == "\"" || ch == "'" {
                inString = ch
                continue
            }

            switch ch {
            case "(":
                parenDepth += 1
            case ")":
                parenDepth = max(0, parenDepth - 1)
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
            case "{":
                braceDepth += 1
            case "}":
                braceDepth = max(0, braceDepth - 1)
            case "<":
                angleDepth += 1
            case ">":
                angleDepth = max(0, angleDepth - 1)
            case "=":
                if parenDepth == 0, bracketDepth == 0, braceDepth == 0, angleDepth == 0 {
                    let cutoff = param.index(param.startIndex, offsetBy: idx)
                    return String(param[..<cutoff]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            default:
                break
            }
        }

        return param
    }

    fileprivate static func splitTopLevelTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var angleDepth = 0
        var inString: Character? = nil
        var escaped = false

        for ch in text {
            if let stringDelimiter = inString {
                current.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == stringDelimiter {
                    inString = nil
                }
                continue
            }

            if ch == "\"" || ch == "'" {
                inString = ch
                current.append(ch)
                continue
            }

            switch ch {
            case "(":
                parenDepth += 1
            case ")":
                parenDepth = max(0, parenDepth - 1)
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
            case "{":
                braceDepth += 1
            case "}":
                braceDepth = max(0, braceDepth - 1)
            case "<":
                angleDepth += 1
            case ">":
                angleDepth = max(0, angleDepth - 1)
            default:
                break
            }

            if ch.isWhitespace, parenDepth == 0, bracketDepth == 0, braceDepth == 0, angleDepth == 0 {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(ch)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens.filter { !$0.isEmpty }
    }

    fileprivate static func extractSwiftParameterTypes(_ paramList: String) -> [String] {
        let params = paramList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var types: [String] = []

        for p in params {
            let noDefault = p.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) ?? p
            let cleaned = noDefault.replacing(swiftDecoratorRegex, with: "")
                .trimmingCharacters(in: .whitespaces)

            if let colonIndex = cleaned.firstIndex(of: ":") {
                let afterColon = cleaned[cleaned.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                if let eqIndex = afterColon.firstIndex(of: "=") {
                    let rawType = afterColon[..<eqIndex].trimmingCharacters(in: .whitespaces)
                    types.append(String(rawType))
                } else {
                    types.append(String(afterColon))
                }
            } else {
                types.append("untyped")
            }
        }
        return types
    }

    fileprivate static func parsePythonParameterList(_ paramList: String) -> [String] {
        let chunks = paramList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var results = [String]()

        for chunk in chunks {
            // varargs or kwargs
            if chunk.hasPrefix("*") || chunk.hasPrefix("**") {
                results.append("untyped")
                continue
            }
            let noDefault = chunk.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) ?? chunk
            if let colonIndex = noDefault.firstIndex(of: ":") {
                let afterColon = noDefault[noDefault.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                results.append(String(afterColon))
            } else {
                results.append("untyped")
            }
        }
        return results
    }

    fileprivate static func parseRustParameterList(_ paramList: String) -> [String] {
        let chunks = paramList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var results = [String]()

        for chunk in chunks {
            let noDefault = chunk.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) ?? chunk
            let normalizedRaw = noDefault.replacing(multiWhitespaceRegex, with: " ")
                .trimmingCharacters(in: .whitespaces)
            if normalizedRaw == "self"
                || normalizedRaw == "&self"
                || normalizedRaw == "&mut self"
                || normalizedRaw == "mut self"
            {
                continue
            }

            let stripped = noDefault.replacing(rustDecoratorRegex, with: "")
                .trimmingCharacters(in: .whitespaces)

            if let colonIndex = stripped.firstIndex(of: ":") {
                let afterColon = stripped[stripped.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                results.append(String(afterColon))
            } else {
                results.append("untyped")
            }
        }
        return results
    }
}

extension LanguageTypeExtractor {
    enum TS {
        static func extractTypeAnnotation(from line: String) -> String? {
            LanguageTypeExtractor.extractTSTypeAnnotation(from: line)
        }

        static func extractTypeAliasRHS(from line: String) -> String? {
            LanguageTypeExtractor.extractTSTypeAliasRHS(from: line)
        }

        static func extractReturnType(from signature: String, stats: CodeMapPerformanceCollector? = nil) -> String? {
            LanguageTypeExtractor.extractTSReturnType(from: signature, stats: stats)
        }

        static func parseParameterTypes(from paramList: String) -> [String] {
            LanguageTypeExtractor.parseTSParameterList(paramList)
        }
    }
}

private extension [String: String] {
    /// After capturing ["name","paramList","returnType"], parse the paramList
    /// for each language and store the result in "parameterTypes".
    /// Also does final trimming on "returnType".
    func thenParseParameters(language: LanguageType) -> [String: String] {
        var result = self

        if let paramList = self["paramList"] {
            let trimmedList = paramList.trimmingCharacters(in: .whitespacesAndNewlines)
            switch language {
            case .python:
                let paramTypes = LanguageTypeExtractor.parsePythonParameterList(trimmedList)
                result["parameterTypes"] = paramTypes.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            case .rust:
                let paramTypes = LanguageTypeExtractor.parseRustParameterList(trimmedList)
                result["parameterTypes"] = paramTypes.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            case .swift:
                let paramTypes = LanguageTypeExtractor.extractSwiftParameterTypes(trimmedList)
                result["parameterTypes"] = paramTypes.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            case .ts, .tsx:
                let paramTypes = LanguageTypeExtractor.parseTSParameterList(trimmedList)
                result["parameterTypes"] = paramTypes.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            case .dart:
                let paramTypes = LanguageTypeExtractor.parseDartParameterList(trimmedList)
                result["parameterTypes"] = paramTypes.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            default:
                let paramTypes = LanguageTypeExtractor.parseCStyleParameterList(trimmedList)
                result["parameterTypes"] = paramTypes.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            }
        }

        // Trim "returnType" if present
        if let ret = result["returnType"] {
            result["returnType"] = ret.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }
}
